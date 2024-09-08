defmodule RadioBeam.Room.Timeline.Core do
  @moduledoc """
  Functional core for syncing with clients and reading the event graph.
  """

  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline
  alias RadioBeam.Room.Timeline.Filter

  @doc """
  Encodes a list of event IDs into a `since` token that can be provided in the
  `next_batch` or `prev_batch` field of a sync response, or the /messages
  endpoint.

  NOTE: the length of this token grows linearly with the number of event IDs.
  This may begin to become an issue for users in 100s of rooms (or more).
  Consider `:zlib` when the length of `event_ids` exceeds a certain size.

    iex> Core.encode_since_token(["$2feFTNOauB6SwzuhkqcelJdqyyolUMYTN6SfLWY9MJ8=", "$YF3P23hUffTxMiR05ZEPdhXaRPpzaW-XC1zqcPmu1rE="])
    "batch:2feFTNOauB6SwzuhkqcelJdqyyolUMYTN6SfLWY9MJ8=YF3P23hUffTxMiR05ZEPdhXaRPpzaW-XC1zqcPmu1rE="
  """
  def encode_since_token(event_ids) do
    for "$" <> hash64 <- event_ids, into: "batch:", do: hash64
  end

  @doc """
  Decodes a since token (created with `encode_since_token/1`) back into a list
  of event IDs.

    iex> Core.decode_since_token("batch:2feFTNOauB6SwzuhkqcelJdqyyolUMYTN6SfLWY9MJ8=YF3P23hUffTxMiR05ZEPdhXaRPpzaW-XC1zqcPmu1rE=")
    ["$2feFTNOauB6SwzuhkqcelJdqyyolUMYTN6SfLWY9MJ8=", "$YF3P23hUffTxMiR05ZEPdhXaRPpzaW-XC1zqcPmu1rE="]
  """
  def decode_since_token("batch:" <> token) when rem(byte_size(token), 44) == 0 do
    for hash64 <- Enum.map(0..(byte_size(token) - 1)//44, &binary_slice(token, &1..(&1 + 43))) do
      "$" <> hash64
    end
  end

  def sync_timeline(config, user_id) do
    %Timeline{} = timeline = config.event_producer.(config.filter)

    oldest_event = List.first(timeline.events)

    if is_nil(oldest_event) and not config.full_state? do
      :no_update
    else
      get_senders = fn -> get_tl_senders(timeline.events, user_id) end
      state_delta = build_state_delta(config, oldest_event, get_senders)

      cond do
        Enum.empty?(state_delta) and
            (Enum.empty?(timeline.events) or not allowed_room?(config.room.id, config.filter.timeline.rooms)) ->
          :no_update

        :else ->
          %{
            # TODO: I think the event format needs to apply to state events here too? 
            state: state_delta,
            timeline: %Timeline{timeline | events: format(timeline.events, config.filter, config.room.version)}
          }
      end
    end
  end

  def format(timeline, filter, room_version) do
    format = String.to_existing_atom(filter.format)
    Enum.map(timeline, &(&1 |> PDU.to_event(room_version, :strings, format) |> Filter.take_fields(filter.fields)))
  end

  def handle_room_message(msg, config_map, user_id) do
    case msg do
      {:room_event, room_id, pdu} ->
        tl_config = Map.fetch!(config_map, room_id)

        if :radio_beam_room_queries.passes_filter(tl_config.filter.timeline, pdu.type, pdu.sender, pdu.content) and
             PDU.visible_to_user?(pdu, user_id, pdu.depth) do
          case sync_timeline(%{tl_config | event_producer: fn _filter -> Timeline.complete([pdu]) end}, user_id) do
            :no_update -> :keep_waiting
            timeline -> {%{join: %{tl_config.room.id => timeline}}, [pdu.event_id]}
          end
        else
          :keep_waiting
        end

      {:room_stripped_state, _room_id, _pdu} ->
        # see TODO in Timeline.sync_one
        :keep_waiting

      {:room_invite, room_id, pdu} ->
        tl_config = Map.fetch!(config_map, room_id)
        event = PDU.to_event(pdu, tl_config.room.version, :strings)
        room = Room.Core.update_room_state(tl_config.room, event)
        {%{invite: %{room.id => %{invite_state: %{events: Room.stripped_state(room)}}}}, [pdu.event_id]}
    end
  end

  def build_state_delta(config, oldest_event, get_senders) do
    if allowed_room?(config.room.id, config.filter.state.rooms) do
      state_at_last_sync =
        unless config.last_sync_pdus == :none or config.full_state? do
          init_state = config.last_sync_pdus |> List.first() |> Map.get(:prev_state)

          Enum.reduce(config.last_sync_pdus, init_state, fn pdu, state ->
            if is_nil(pdu.state_key) do
              state
            else
              event = PDU.to_event(pdu, config.room.version, :strings)
              Map.put(state, {pdu.type, pdu.state_key}, event)
            end
          end)
        end

      state_delta(state_at_last_sync, oldest_event, config.filter.state, get_senders)
    else
      []
    end
  end

  defp state_delta(nil, tl_start_event, filter, get_senders) do
    tl_start_event.prev_state
    |> Stream.map(fn {_, event} -> event end)
    |> Enum.filter(&passes_filter?(&1, filter, get_senders))
  end

  defp state_delta(state_at_last_sync, tl_start_event, filter, get_senders) do
    for {k, %{"event_id" => cur_event_id} = cur_event} <- tl_start_event.prev_state, reduce: [] do
      acc ->
        case get_in(state_at_last_sync, [k, "event_id"]) do
          ^cur_event_id ->
            acc

          _cur_event_id_or_nil ->
            if passes_filter?(cur_event, filter, get_senders) do
              [cur_event | acc]
            else
              acc
            end
        end
    end
  end

  defp passes_filter?(event, filter, get_senders) do
    (filter.memberships not in [:lazy, :lazy_redundant] or event["sender"] in get_senders.()) and
      :radio_beam_room_queries.passes_filter(filter, event["type"], event["sender"], event["content"])
  end

  defp get_tl_senders(events, user_id) do
    events
    |> MapSet.new(& &1.sender)
    |> MapSet.put(user_id)
  end

  defp allowed_room?(room_id, {:allowlist, allowlist}), do: room_id in allowlist
  defp allowed_room?(room_id, {:denylist, denylist}), do: room_id not in denylist
  defp allowed_room?(_room_id, :none), do: true
end
