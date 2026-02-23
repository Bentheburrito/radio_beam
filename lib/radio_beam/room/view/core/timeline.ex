defmodule RadioBeam.Room.View.Core.Timeline do
  @moduledoc """
  Tracks a room's events and state that will be sent to clients when requested.
  """
  alias RadioBeam.PubSub
  alias RadioBeam.Room
  alias RadioBeam.Room.EventRelationships
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Room.View.Core.Timeline.EventMetadata
  alias RadioBeam.Room.View.Core.Timeline.TimestampToEventIDIndex
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.Room.View.Core.Timeline.VisibilityGroup

  @attrs ~w|topological_id_to_event_id topological_id_ord_set event_metadata member_metadata visibility_groups visibility_exceptions timestamp_to_event_id_index|a
  @enforce_keys @attrs
  defstruct @attrs
  @typep t() :: %__MODULE__{}

  @type from() :: {TopologicalID.t(), :forward | :backward} | :root | :tip

  def new! do
    %__MODULE__{
      topological_id_to_event_id: %{},
      topological_id_ord_set: TopologicalID.OrderedSet.new!(),
      event_metadata: %{},
      member_metadata: %{},
      visibility_groups: %{},
      visibility_exceptions: %{},
      timestamp_to_event_id_index: TimestampToEventIDIndex.new!()
    }
  end

  def key_for(%{id: room_id}, _pdu), do: {:ok, {__MODULE__, room_id}}

  def handle_pdu(%__MODULE__{} = timeline, %Room{} = room, %PDU{} = pdu) do
    prev_events_topo_id_stream =
      timeline.event_metadata
      |> Map.take(pdu.prev_event_ids)
      |> Stream.map(fn {_event_id, metadata} -> metadata.topological_id end)

    pdu_topo_id = TopologicalID.new!(pdu, prev_events_topo_id_stream)

    member_metadata =
      if pdu.event.type == "m.room.member" and pdu.event.content["membership"] == "join" do
        latest_topo_id = later_join_topo_id(timeline, pdu.event.state_key, pdu_topo_id)
        Map.put(timeline.member_metadata, pdu.event.state_key, %{latest_known_join_topo_id: latest_topo_id})
      else
        timeline.member_metadata
      end

    visibility_group = VisibilityGroup.from_state!(room.state, pdu)
    visibility_group_id = VisibilityGroup.id(visibility_group)

    event_metadata =
      with {:ok, %{"event_id" => parent_event_id}} <- Map.fetch(pdu.event.content, "m.relates_to"),
           true <- EventRelationships.aggregable?(pdu.event) do
        timeline.event_metadata
        |> Map.update(
          parent_event_id,
          EventMetadata.new!(:unknown, visibility_group_id, [pdu.event.id]),
          &EventMetadata.append_bundled_event_id(&1, pdu.event.id)
        )
        |> Map.update(
          pdu.event.id,
          EventMetadata.new!(pdu_topo_id, visibility_group_id),
          &EventMetadata.put_topological_id(&1, pdu_topo_id)
        )
      else
        _ ->
          Map.update(
            timeline.event_metadata,
            pdu.event.id,
            EventMetadata.new!(pdu_topo_id, visibility_group_id),
            &EventMetadata.put_topological_id(&1, pdu_topo_id)
          )
      end

    visibility_exceptions =
      case pdu.event.type do
        "m.room.history_visibility" ->
          if pdu.event.prev_state_content != :none do
            Map.put(
              timeline.visibility_exceptions,
              pdu.event.id,
              {:history_visibility, pdu.event.prev_state_content["history_visibility"]}
            )
          else
            timeline.visibility_exceptions
          end

        "m.room.member" ->
          if pdu.event.prev_state_content != :none do
            Map.put(
              timeline.visibility_exceptions,
              pdu.event.id,
              {:member, pdu.event.state_key, pdu.event.prev_state_content["membership"]}
            )
          else
            timeline.visibility_exceptions
          end

        _ ->
          timeline.visibility_exceptions
      end

    timeline =
      struct!(timeline,
        topological_id_to_event_id: Map.put(timeline.topological_id_to_event_id, pdu_topo_id, pdu.event.id),
        topological_id_ord_set: TopologicalID.OrderedSet.put(timeline.topological_id_ord_set, pdu_topo_id),
        event_metadata: event_metadata,
        member_metadata: member_metadata,
        visibility_groups: Map.put(timeline.visibility_groups, visibility_group_id, visibility_group),
        visibility_exceptions: visibility_exceptions,
        timestamp_to_event_id_index:
          TimestampToEventIDIndex.put(timeline.timestamp_to_event_id_index, pdu.event.origin_server_ts, pdu.event.id)
      )

    {timeline, pubsub_messages(room.id, pdu_topo_id, pdu)}
  end

  defp later_join_topo_id(timeline, user_id, pdu_topo_id) do
    case timeline.member_metadata[user_id][:latest_known_join_topo_id] do
      nil ->
        pdu_topo_id

      latest_known_join_topo_id ->
        if TopologicalID.compare(pdu_topo_id, latest_known_join_topo_id) == :gt do
          pdu_topo_id
        else
          latest_known_join_topo_id
        end
    end
  end

  @spec topological_stream(
          t(),
          RadioBeam.User.id(),
          from(),
          (Room.event_id() -> PDU.t())
        ) :: Enumerable.t(Room.event_id()) | {:error, :event_id_not_found | :event_not_ordered_yet}
  def topological_stream(%__MODULE__{} = timeline, user_id, {%TopologicalID{} = from, direction}, fetch_pdu!) do
    latest_known_join_topo_id = get_latest_known_join_topo_id(timeline, user_id)

    timeline.topological_id_ord_set
    |> TopologicalID.OrderedSet.stream_from(from, direction)
    |> Stream.filter(&visible_to_user?(timeline, user_id, latest_known_join_topo_id, &1))
    |> Stream.map(fn topological_id ->
      event_id = Map.fetch!(timeline.topological_id_to_event_id, topological_id)

      event_visible? =
        fn {_event_id, metadata} ->
          visible_to_user?(timeline, user_id, latest_known_join_topo_id, metadata.topological_id)
        end

      visible_bundled_events =
        timeline.event_metadata[event_id].bundled_event_ids
        |> Stream.map(&{&1, Map.fetch!(timeline.event_metadata, &1)})
        |> Stream.filter(event_visible?)
        |> Enum.map(fn {event_id, metadata} -> Event.new!(metadata.topological_id, fetch_pdu!.(event_id), []) end)

      Event.new!(topological_id, fetch_pdu!.(event_id), visible_bundled_events)
    end)
  end

  def topological_stream(timeline, user_id, :root, fetch_pdu!),
    do: topological_stream(timeline, user_id, {timeline.topological_id_ord_set.first_id, :forward}, fetch_pdu!)

  def topological_stream(timeline, user_id, :tip, fetch_pdu!),
    do: topological_stream(timeline, user_id, {timeline.topological_id_ord_set.last_id, :backward}, fetch_pdu!)

  def topological_stream(timeline, user_id, {"$" <> _ = from_event_id, dir}, fetch_pdu!) do
    case Map.fetch(timeline.event_metadata, from_event_id) do
      {:ok, %{topological_id: %TopologicalID{} = from_topo_id}} ->
        topological_stream(timeline, user_id, {from_topo_id, dir}, fetch_pdu!)

      {:ok, %{}} ->
        {:error, :event_not_ordered_yet}

      :error ->
        {:error, :event_id_not_found}
    end
  end

  defp get_latest_known_join_topo_id(timeline, user_id) do
    case timeline.member_metadata do
      %{^user_id => %{latest_known_join_topo_id: %TopologicalID{} = topo_id}} -> topo_id
      _ -> :never_joined
    end
  end

  # credo:disable-for-lines:47 Credo.Check.Refactor.CyclomaticComplexity
  defp visible_to_user?(timeline, user_id, latest_known_join_topo_id, topological_id) do
    event_id = Map.fetch!(timeline.topological_id_to_event_id, topological_id)
    event_metadata = Map.fetch!(timeline.event_metadata, event_id)

    case event_metadata.visibility_group_id do
      :world_readable ->
        true

      event_visibility_group_id ->
        %VisibilityGroup{history_visibility: visibility_at_event} =
          event_visibility_group = Map.fetch!(timeline.visibility_groups, event_visibility_group_id)

        user_joined_after_event? =
          case latest_known_join_topo_id do
            :never_joined -> false
            latest_known_join_topo_id -> TopologicalID.compare(latest_known_join_topo_id, topological_id) == :gt
          end

        # For m.room.history_visibility events themselves, the user should be
        # allowed to see the event if the history_visibility before or after
        # the event would allow them to see it
        visibilities_before_and_at_event =
          case Map.get(timeline.visibility_exceptions, event_id) do
            {:history_visibility, visibility_before_event} -> [visibility_at_event, visibility_before_event]
            _else -> [visibility_at_event]
          end

        # for the user’s own m.room.member events, the user should be allowed to
        # see the event if their membership before or after the event would
        # allow them to see it
        user_joined_at_event? =
          case Map.get(timeline.visibility_exceptions, event_id) do
            {:member, ^user_id, "join"} -> true
            _else -> user_id in event_visibility_group.joined
          end

        user_invited_at_event? =
          case Map.get(timeline.visibility_exceptions, event_id) do
            {:member, ^user_id, "invite"} -> true
            _else -> user_id in event_visibility_group.invited
          end

        user_joined_at_event? or
          "world_readable" in visibilities_before_and_at_event or
          ("shared" in visibilities_before_and_at_event and user_joined_after_event?) or
          ("invited" in visibilities_before_and_at_event and user_invited_at_event? and user_joined_after_event?)
    end
  end

  def get_visible_events(%__MODULE__{} = timeline, event_ids, user_id, fetch_pdu!, bundle_aggregations? \\ true) do
    latest_known_join_topo_id = get_latest_known_join_topo_id(timeline, user_id)

    event_visible? =
      fn {_event_id, metadata} ->
        visible_to_user?(timeline, user_id, latest_known_join_topo_id, metadata.topological_id)
      end

    event_ids
    |> Stream.map(&{&1, timeline.event_metadata[&1]})
    |> Stream.reject(fn {_event_id, maybe_metadata} -> is_nil(maybe_metadata) end)
    |> Stream.filter(event_visible?)
    |> Stream.map(fn {event_id, metadata} ->
      visible_bundled_events =
        if bundle_aggregations? do
          timeline.event_metadata[event_id].bundled_event_ids
          |> Stream.map(&{&1, Map.fetch!(timeline.event_metadata, &1)})
          |> Stream.filter(event_visible?)
          |> Enum.map(fn {event_id, metadata} -> Event.new!(metadata.topological_id, fetch_pdu!.(event_id), []) end)
        else
          []
        end

      Event.new!(metadata.topological_id, fetch_pdu!.(event_id), visible_bundled_events)
    end)
  end

  def stream_event_ids_closest_to_ts(%__MODULE__{} = timeline, user_id, timestamp, direction) do
    latest_known_join_topo_id = timeline.member_metadata[user_id][:latest_known_join_topo_id] || :never_joined

    event_visible? =
      fn {_event_id, metadata, _ts} ->
        visible_to_user?(timeline, user_id, latest_known_join_topo_id, metadata.topological_id)
      end

    timeline.timestamp_to_event_id_index
    |> TimestampToEventIDIndex.stream_nearest_event_ids(timestamp, direction)
    |> Stream.map(fn {ts, event_id} -> {event_id, timeline.event_metadata[event_id], ts} end)
    |> Stream.reject(fn {_event_id, maybe_metadata, _ts} -> is_nil(maybe_metadata) end)
    |> Stream.filter(event_visible?)
    |> Stream.map(fn {event_id, _metadata, origin_server_ts} -> {event_id, origin_server_ts} end)
  end

  defp pubsub_messages(room_id, topological_id, pdu) do
    event = Event.new!(topological_id, pdu, [])
    new_event_message = {PubSub.all_room_events(room_id), {:room_event, room_id, event}}

    if pdu.event.type == "m.room.member" do
      membership_event_messages =
        case pdu.event do
          %{content: %{"membership" => "invite"}} ->
            [
              {PubSub.invite_events(pdu.event.state_key),
               {:room_invite, pdu.event.state_key, pdu.event.sender, room_id}}
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

  defmodule EventMetadata do
    @moduledoc false
    @enforce_keys ~w|topological_id visibility_group_id|a
    defstruct topological_id: nil, visibility_group_id: nil, bundled_event_ids: []

    def new!(topological_id_or_unknown, visibility_group_id, bundled_event_ids \\ []) do
      %__MODULE__{
        topological_id: topological_id_or_unknown,
        visibility_group_id: visibility_group_id,
        bundled_event_ids: bundled_event_ids
      }
    end

    def put_topological_id(%__MODULE__{} = metadata, %TopologicalID{} = id), do: struct!(metadata, topological_id: id)

    def append_bundled_event_id(%__MODULE__{} = metadata, event_id) do
      update_in(metadata.bundled_event_ids, &[event_id | &1])
    end
  end

  defmodule TimestampToEventIDIndex do
    @moduledoc false
    @round_to_multiples_of :timer.minutes(20)
    @default_cutoff :timer.hours(24)

    # index: %{rounded_origin_server_ts => [{origin_server_ts, event_id}]}
    defstruct index: %{}, min: :infinity, max: 0

    def new!, do: %__MODULE__{index: %{}}

    def put(%__MODULE__{} = ts_index, origin_server_ts, event_id) do
      rounded_timestamp = round_timestamp(origin_server_ts)

      ts_index =
        cond do
          rounded_timestamp < ts_index.min -> put_in(ts_index.min, rounded_timestamp)
          rounded_timestamp > ts_index.max -> put_in(ts_index.max, rounded_timestamp)
          :else -> ts_index
        end

      update_in(ts_index.index[rounded_timestamp], fn
        nil -> [{origin_server_ts, event_id}]
        # TODO: maybe optimize if necessary
        ordered_pairs -> Enum.sort_by([{origin_server_ts, event_id} | ordered_pairs], &elem(&1, 0), &</2)
      end)
    end

    @doc """
    Returns event IDs whose `origin_server_ts` is closest to the given unix
    `timestamp` in the direction of `dir`.
    """
    def stream_nearest_event_ids(%__MODULE__{index: index} = ts_index, timestamp, dir)
        when is_integer(timestamp) and dir in ~w|forward backward|a do
      rounded_timestamp = round_timestamp(timestamp)
      to_add = if dir == :forward, do: @round_to_multiples_of, else: -@round_to_multiples_of

      reached_end? = if dir == :forward, do: fn ts -> ts > ts_index.max end, else: fn ts -> ts < ts_index.min end

      keep_taking? =
        if dir == :forward do
          fn {origin_server_ts, _event_id} -> origin_server_ts <= timestamp + @default_cutoff end
        else
          fn {origin_server_ts, _event_id} -> origin_server_ts >= timestamp - @default_cutoff end
        end

      seeked_to_first_ts? =
        if dir == :forward do
          fn {origin_server_ts, _event_id} -> origin_server_ts <= timestamp end
        else
          fn {origin_server_ts, _event_id} -> origin_server_ts >= timestamp end
        end

      rounded_timestamp
      |> Stream.iterate(&(&1 + to_add))
      |> Stream.take_while(&(not reached_end?.(&1)))
      |> Stream.flat_map(&get_entries_from_index(index, &1, dir))
      |> Stream.drop_while(seeked_to_first_ts?)
      |> Stream.take_while(keep_taking?)

      # !! This needs to be done in the calling code that has user visibility info
      # if dir == :forward, Enum.find first {origin_ts, event_id} where origin_ts >= timestamp
      # if dir == :backward, reverse list, then Enum.find first {origin_ts, event_id} where origin_ts <= timestamp
    end

    defp round_timestamp(timestamp), do: timestamp - rem(timestamp, @round_to_multiples_of)

    defp get_entries_from_index(index, rounded_ts, :forward), do: Map.get(index, rounded_ts, [])
    defp get_entries_from_index(index, rounded_ts, :backward), do: index |> Map.get(rounded_ts, []) |> Enum.reverse()
  end
end
