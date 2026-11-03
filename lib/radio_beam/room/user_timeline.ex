defmodule RadioBeam.Room.UserTimeline do
  @moduledoc """
  API and EventHandler for user-specific views of room events.
  """
  @behaviour RadioBeam.EventHandler

  alias RadioBeam.PubSub
  alias RadioBeam.Room
  alias RadioBeam.Room.Database
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.UserTimeline.Event
  alias RadioBeam.Room.View.RelatedEvents
  alias RadioBeam.User.RoomMemberships

  ### API ###

  @doc """
  Streams events visible to the given `user_id` from the latest events in the
  room, or starting from a different event depending on the given options.
  Events are sorted by their "stream order," which is the order they were
  processed by the homeserver, and not necessarily the order in which they were
  sent, nor the order if you were to crawl the room's event DAG.

  # Options

  - `:from` can be one of the following values:
    - `:tip` (default) - start from the latest known event in the room,
      streaming backward.
    - `:root` - start from the `m.room.create` event, streaming forward.
    - `{:backward, stream_number}` - start from the event of the given
      `stream_number`, streaming backward.
    - `{:forward, stream_number}` - start from the event of the given
      `stream_number`, streaming forward.

  """
  def stream_user_events(room_id, user_id, opts \\ []) do
    latest_join_stream_num = RoomMemberships.latest_join_stream_number(room_id, user_id)

    room_id
    |> Database.stream_room_timeline(opts)
    |> filter_visible(room_id, user_id, latest_join_stream_num)
    |> Enum.map(&pdu_to_event(&1, user_id, Keyword.get(opts, :bundle_events?, true)))
  end

  def fetch_user_event(room_id, user_id, "$" <> _ = event_id) do
    case map_filter_user_events(room_id, user_id, [event_id]) do
      [event] -> {:ok, event}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Maps the given `event_ids` to their timeline events, filtering out any that
  are not visible to the given `user_id` according to the room's membership
  and visibility settings.
  """
  def map_filter_user_events(room_id, user_id, event_ids, bundle_events? \\ true) do
    latest_join_stream_num = RoomMemberships.latest_join_stream_number(room_id, user_id)

    event_ids
    |> filter_visible(room_id, user_id, latest_join_stream_num)
    |> Enum.map(&pdu_to_event(&1, user_id, bundle_events?))
  end

  def nearest_user_event_to_timestamp(room_id, user_id, timestamp, direction) do
    latest_join_stream_num = RoomMemberships.latest_join_stream_number(room_id, user_id)

    maybe_wrapped_event =
      room_id
      |> Database.stream_room_event_ids_from_timestamp(timestamp, direction)
      |> filter_visible(room_id, user_id, latest_join_stream_num)
      |> Stream.take(1)
      |> Enum.map(&pdu_to_event(&1, user_id, true))

    case maybe_wrapped_event do
      [] -> {:error, :not_found}
      [event] -> {:ok, event}
    end
  end

  ### HELPERS ###

  defp filter_visible(event_id_stream, room_id, user_id, latest_join_stream_num) do
    Stream.flat_map(event_id_stream, fn event_id ->
      # TODO: make Room.fetch_pdu private, and pass down as a dep/option
      case Room.fetch_pdu(room_id, event_id) do
        {:ok, %PDU{} = pdu} -> if visible?(room_id, user_id, pdu, latest_join_stream_num), do: [pdu], else: []
        {:error, :not_found} -> []
      end
    end)
  end

  defp visible?(room_id, user_id, %PDU{} = pdu, latest_join_stream_num) do
    history_visibilities_at_pdu = visibilities(room_id, pdu)
    user_memberships_at_pdu = memberships(room_id, user_id, pdu)

    "join" in user_memberships_at_pdu or
      "world_readable" in history_visibilities_at_pdu or
      ("shared" in history_visibilities_at_pdu and user_joined_after_event?(pdu, latest_join_stream_num)) or
      ("invited" in history_visibilities_at_pdu and "invite" in user_memberships_at_pdu and
         user_joined_after_event?(pdu, latest_join_stream_num))
  end

  defp visibilities(room_id, %PDU{event: %{type: "m.room.history_visibility"}} = pdu),
    do: [history_visibility_at(room_id, pdu.event.id), pdu.event.content["history_visibility"]]

  defp visibilities(room_id, %PDU{} = pdu), do: [history_visibility_at(room_id, pdu.event.id)]

  defp history_visibility_at(room_id, "$" <> _ = event_id) do
    case Room.fetch_state_pdu_at(room_id, event_id, "m.room.history_visibility", "") do
      {:ok, pdu} -> pdu.event.content["history_visibility"]
      {:error, :not_found} -> "shared"
    end
  end

  defp memberships(room_id, user_id, %PDU{event: %{type: "m.room.member"}} = pdu),
    do: [membership_at(room_id, user_id, pdu.event.id), pdu.event.content["membership"]]

  defp memberships(room_id, user_id, %PDU{} = pdu), do: [membership_at(room_id, user_id, pdu.event.id)]

  defp membership_at(room_id, user_id, "$" <> _ = event_id) do
    case Room.fetch_state_pdu_at(room_id, event_id, "m.room.member", user_id) do
      {:ok, pdu} -> pdu.event.content["membership"]
      {:error, :not_found} -> "leave"
    end
  end

  defp user_joined_after_event?(%PDU{stream_number: stream_num}, latest_stream_num), do: latest_stream_num > stream_num

  defp pdu_to_event(%PDU{} = pdu, user_id, bundle_events?) do
    %RelatedEvents{related_by_event_id: related_by_event_id} = RelatedEvents.fetch!(pdu.event.room_id)

    bundled_events =
      if bundle_events? do
        pdu.event.room_id
        |> map_filter_user_events(user_id, Map.get(related_by_event_id, pdu.event.id, []))
        |> Enum.sort({:desc, Event})
      else
        []
      end

    Event.new!(pdu, bundled_events, user_id)
  end

  @impl RadioBeam.EventHandler
  def handle_pdu(%PDU{} = pdu) do
    with :ok <- Database.upsert_room_timeline_stream_pointer(pdu.event.room_id, pdu.stream_number, pdu.event.id),
         :ok <- Database.upsert_room_timestamp_pointer(pdu.event.room_id, pdu.event.origin_server_ts, pdu.event.id),
         :ok <- RelatedEvents.handle_pdu(pdu) do
      for {topic, message} <- pubsub_messages(pdu), do: :ok = PubSub.broadcast(topic, message)

      :ok
    end
  end

  defp pubsub_messages(pdu) do
    event = Event.new!(pdu, [], nil)
    new_event_message = {PubSub.all_room_events(pdu.event.room_id), {:room_event, pdu.event.room_id, event}}

    if pdu.event.type == "m.room.member" do
      membership_event_messages =
        case pdu.event do
          %{content: %{"membership" => "invite"}} ->
            [
              {PubSub.invite_events(pdu.event.state_key),
               {:room_invite, pdu.event.state_key, pdu.event.sender, pdu.event.room_id}}
            ]

          %{content: %{"membership" => membership}} when membership in ~w|join leave ban kick| ->
            crypto_id_change_message = {PubSub.user_membership_or_crypto_id_changed(), :crypto_id_changed}

            if membership == "join" and not match?(%{"membership" => "join"}, pdu.event.prev_state_content) do
              [
                crypto_id_change_message,
                {PubSub.user_joined_room(pdu.event.state_key), {:room_joined, event}}
              ]
            else
              [crypto_id_change_message]
            end
        end

      [new_event_message | membership_event_messages]
    else
      [new_event_message]
    end
  end

  @impl RadioBeam.EventHandler
  # handle_pdu is idempotent
  def reset_to(event_number), do: {:ok, event_number}
end
