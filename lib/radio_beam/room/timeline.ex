defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  require Logger

  alias Phoenix.PubSub
  alias RadioBeam.Room.Timeline.Filter
  alias RadioBeam.Room.Timeline.SyncBatch
  alias RadioBeam.PDU
  alias RadioBeam.PubSub, as: PS
  alias RadioBeam.Room

  def get_messages(room_id, user_id, direction, from, to, opts \\ [])

  def get_messages(%Room{} = room, user_id, direction, from, to, opts) do
    from_event_ids = parse_token(from, room, direction)
    to_event_ids = parse_token(to, room, direction)

    order =
      case direction do
        :forward -> :ascending
        :backward -> :descending
      end

    filter = opts |> Keyword.get(:filter, %{}) |> Filter.parse()
    # TODO...there's possibly a :limit opt passed too, but the filter 
    # also has limiting capabilities???

    latest_joined_at_depth = Room.users_latest_join_depth(room.id, user_id)

    case timeline(room.id, user_id, from_event_ids, to_event_ids, filter, latest_joined_at_depth, order) do
      %{limited: true, events: events, prev_batch: prev_batch} ->
        members = MapSet.new(events, &Map.fetch!(room.state, {"m.room.member", &1.sender}))
        events = events |> Enum.reverse() |> format(filter)
        # TOIMPL: add support for lazy_load_members and include_redundant_members
        %{chunk: events, state: MapSet.to_list(members), start: from, end: prev_batch}

      %{limited: false, events: events} ->
        members = MapSet.new(events, &Map.fetch!(room.state, {"m.room.member", &1.sender}))
        events = events |> Enum.reverse() |> format(filter)
        %{chunk: events, state: MapSet.to_list(members), start: from}
    end
  end

  def get_messages(room_id, user_id, direction, from, to, opts) do
    case Memento.transaction(fn -> Memento.Query.read(Room, room_id) end) do
      {:ok, %Room{state: %{{"m.room.member", ^user_id} => %{"content" => %{"membership" => "join"}}}} = room} ->
        {:ok, get_messages(room, user_id, direction, from, to, opts)}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp parse_token("batch:" <> _ = next_batch_token, room, _dir),
    do: Map.get(parse_since_token(next_batch_token), room.id, [])

  defp parse_token("$" <> _ = prev_batch_token, _room, _dir), do: String.split(prev_batch_token, "|")
  defp parse_token(:limit, room, :forward), do: room.latest_event_ids
  defp parse_token(:limit, _room, :backward), do: []
  defp parse_token(:first, _room, :forward), do: []
  defp parse_token(:last, room, :backward), do: room.latest_event_ids

  def max_events(type) when type in [:timeline, :state] do
    Application.get_env(:radio_beam, :max_events)[type]
  end

  def sync(room_ids, user_id, opts \\ []) do
    filter = opts |> Keyword.get(:filter, %{}) |> Filter.parse()
    opts = Keyword.put(opts, :filter, filter)

    {rooms, batch_map} = sync_with_room_ids(room_ids, user_id, opts)
    {:ok, next_batch} = SyncBatch.put(batch_map)

    %{
      rooms: rooms,
      next_batch: next_batch,
      # TOIMPL
      account_data: %{},
      device_lists: [],
      device_one_time_keys_count: 0,
      presence: %{},
      to_device: %{}
    }
  end

  @init_rooms_acc {%{join: %{}, invite: %{}, knock: %{}, leave: %{}}, _batch_map = %{}}
  defp sync_with_room_ids(room_ids, user_id, opts) do
    since = Keyword.get(opts, :since, :latest)
    filter = Keyword.get(opts, :filter, %{})
    last_sync_event_map = parse_since_token(since)

    room_ids =
      case filter.rooms do
        {:allowlist, allowlist} -> Enum.filter(room_ids, &(&1 in allowlist))
        {:denylist, denylist} -> Enum.reject(room_ids, &(&1 in denylist))
        :none -> room_ids
      end

    room_ids
    |> Enum.reduce(@init_rooms_acc, &build_room_sync(&1, user_id, last_sync_event_map, filter.include_leave?, &2, opts))
    |> await_if_no_updates(user_id, opts)
  end

  defp build_room_sync(room_id, user_id, last_sync_event_map, include_leave?, {rooms, batch_map}, opts) do
    %Room{} = room = Memento.transaction!(fn -> Memento.Query.read(Room, room_id) end)

    case get_in(room.state, [{"m.room.member", user_id}, "content", "membership"]) do
      "join" ->
        stop_at_any = Map.get(last_sync_event_map, room.id, [])

        :ok = PubSub.subscribe(PS, PS.all_room_events(room_id))

        opts = Keyword.put(opts, :latest_joined_at_depth, room.depth)

        rooms =
          case room_timeline_sync(room, user_id, room.latest_event_ids, stop_at_any, opts) do
            :no_update -> rooms
            room_update -> put_in(rooms, [:join, room_id], room_update)
          end

        {rooms, Map.update(batch_map, room.id, room.latest_event_ids, &(room.latest_event_ids ++ &1))}

      # TODO: should the invite reflect changes to stripped state events that
      # happened after the invite?
      "invite" when is_map_key(last_sync_event_map, room_id) ->
        {rooms, Map.update(batch_map, room.id, room.latest_event_ids, &(room.latest_event_ids ++ &1))}

      "invite" ->
        {put_in(rooms, [:invite, room_id], invited_room_sync(room)),
         Map.update(batch_map, room.id, room.latest_event_ids, &(room.latest_event_ids ++ &1))}

      "knock" ->
        Logger.info("TOIMPL: sync with knock rooms")
        {rooms, batch_map}

      "leave" when not include_leave? ->
        {rooms, Map.update(batch_map, room.id, room.latest_event_ids, &(room.latest_event_ids ++ &1))}

      "leave" ->
        stop_at_any = Map.get(last_sync_event_map, room.id, [])

        user_leave_event_id = room.state[{"m.room.member", user_id}]["event_id"]
        {:ok, pdu} = PDU.get(user_leave_event_id)

        opts = Keyword.put(opts, :latest_joined_at_depth, pdu.depth - 1)

        rooms =
          case room_timeline_sync(room, user_id, [user_leave_event_id], stop_at_any, opts) do
            :no_update -> rooms
            room_update -> put_in(rooms, [:leave, room_id], room_update)
          end

        {rooms, Map.update(batch_map, room.id, [pdu.event_id], &[pdu.event_id | &1])}
    end
  end

  defp await_if_no_updates({rooms, batch_map}, user_id, opts) do
    if Enum.all?(rooms, fn {_, map} -> map_size(map) == 0 end) do
      timeout = Keyword.get(opts, :timeout, 0)

      case await_next_event(timeout) do
        :timeout ->
          {rooms, batch_map}

        {:update, room_id, rem_timeout} ->
          sync_with_room_ids([room_id], user_id, Keyword.put(opts, :timeout, rem_timeout))
      end
    else
      {rooms, batch_map}
    end
  end

  defp await_next_event(timeout) do
    time_before_wait = :os.system_time(:millisecond)

    receive do
      {:room_update, room_id} ->
        new_timeout = max(0, timeout - (:os.system_time(:millisecond) - time_before_wait))
        {:update, room_id, new_timeout}
    after
      timeout -> :timeout
    end
  end

  defp parse_since_token(:latest), do: %{}

  defp parse_since_token(since) do
    case SyncBatch.pop(since) do
      {:ok, %SyncBatch{batch_map: batch_map}} ->
        batch_map

      {:error, error} ->
        Logger.error(
          "error trying to get a sync batch using `since` token #{inspect(since)}: #{inspect(error)}. Doing an inital sync instead"
        )

        parse_since_token(:latest)
    end
  end

  @spec room_timeline_sync(Room.t(), String.t(), list(), list(), keyword()) :: map() | :no_update
  defp room_timeline_sync(room, user_id, event_ids, stop_at_any, opts) do
    full_state? = Keyword.get(opts, :full_state?, false)
    filter = Keyword.get(opts, :filter, %{})
    latest_joined_at_depth = Keyword.get(opts, :latest_joined_at_depth, -1)

    timeline = timeline(room.id, user_id, event_ids, stop_at_any, filter, latest_joined_at_depth)

    oldest_event = List.first(timeline.events)

    if is_nil(oldest_event) and not full_state? do
      :no_update
    else
      tl_events = if allowed_room?(room.id, filter.timeline.rooms), do: timeline.events, else: []

      state_delta =
        cond do
          not allowed_room?(room.id, filter.state.rooms) ->
            []

          not Keyword.has_key?(opts, :since) or full_state? ->
            state_delta(nil, oldest_event, filter.state)

          :else ->
            state_delta(List.last(stop_at_any), oldest_event, filter.state)
        end

      if Enum.empty?(state_delta) and Enum.empty?(tl_events) do
        :no_update
      else
        %{
          # TODO: I think the event format needs to apply to state events here too? 
          state: state_delta,
          timeline: %{timeline | events: format(tl_events, filter)},
          # TOIMPL
          account_data: %{},
          ephemeral: %{},
          summary: %{},
          unread_notifications: %{},
          unread_thread_notifications: %{}
        }
      end
    end
  end

  defp allowed_room?(room_id, {:allowlist, allowlist}), do: room_id in allowlist
  defp allowed_room?(room_id, {:denylist, denylist}), do: room_id not in denylist
  defp allowed_room?(_room_id, :none), do: true

  defp timeline(room_id, user_id, begin_event_ids, end_event_ids, filter, latest_joined_at_depth, order \\ :descending) do
    fn ->
      latest_event_depth = PDU.max_depth_of_all(room_id, begin_event_ids)
      last_sync_depth = PDU.max_depth_of_all(room_id, end_event_ids)

      # by doing this, the caller doesn't need to know which list of event_ids
      # is actually the begining/earlier or end/later than the other
      {last_sync_depth, latest_event_depth} =
        if last_sync_depth > latest_event_depth do
          {latest_event_depth, last_sync_depth}
        else
          {last_sync_depth, latest_event_depth}
        end

      cursor =
        PDU.timeline_cursor(
          room_id,
          user_id,
          filter.timeline,
          latest_event_depth,
          last_sync_depth,
          latest_joined_at_depth,
          [],
          order
        )

      tl_event_stream = PDU.next_answers(cursor, filter.timeline.limit)

      next_event =
        case Enum.to_list(PDU.next_answers(cursor, 1, :cleanup)) do
          [] -> :none
          [next_event | _] -> next_event
        end

      {next_event, Enum.reverse(tl_event_stream)}
    end
    |> Memento.transaction()
    |> case do
      {:ok, {:none, timeline}} ->
        %{limited: false, events: timeline}

      {:ok, {next_event, timeline}} ->
        prev_batch = if order == :descending, do: next_event.event_id, else: Enum.join(next_event.prev_events, "|")
        %{limited: true, events: timeline, prev_batch: prev_batch}

      {:error, error} ->
        Logger.error("tried to fetch a timeline of events for #{inspect(user_id)}, but got error: #{inspect(error)}")
        %{limited: false, events: []}
    end
  end

  defp format(timeline, filter) do
    format = String.to_existing_atom(filter.format)
    Enum.map(timeline, &(&1 |> PDU.to_event(:strings, format) |> Filter.take_fields(filter.fields)))
  end

  defp state_delta(nil, tl_start_event, filter) do
    tl_start_event.prev_state
    |> Stream.map(fn {_, event} -> event end)
    |> Enum.filter(&:radio_beam_room_queries.passes_filter(filter, &1["type"], &1["sender"], &1["content"]))
  end

  defp state_delta(last_sync_event_id, tl_start_event, filter) do
    {:ok, last_sync_event} = PDU.get(last_sync_event_id)

    old_state =
      if is_nil(last_sync_event.state_key) do
        last_sync_event.prev_state
      else
        event = PDU.to_event(last_sync_event, :strings)
        Map.put(last_sync_event.prev_state, {last_sync_event.type, last_sync_event.state_key}, event)
      end

    for {k, %{"event_id" => cur_event_id} = cur_event} <- tl_start_event.prev_state, reduce: [] do
      acc ->
        case get_in(old_state, [k, "event_id"]) do
          ^cur_event_id ->
            acc

          _cur_event_id_or_nil ->
            if :radio_beam_room_queries.passes_filter(
                 filter,
                 cur_event["type"],
                 cur_event["sender"],
                 cur_event["content"]
               ) do
              [cur_event | acc]
            else
              acc
            end
        end
    end
  end

  @stripped_state_keys [
    {"m.room.create", ""},
    {"m.room.name", ""},
    {"m.room.avatar", ""},
    {"m.room.topic", ""},
    {"m.room.join_rules", ""},
    {"m.room.canonical_alias", ""},
    {"m.room.encryption", ""}
  ]
  defp invited_room_sync(room) do
    state_events = room.state |> Map.take(@stripped_state_keys) |> Enum.map(fn {_, event} -> strip(event) end)
    %{invite_state: %{events: state_events}}
  end

  @stripped_keys ["content", "sender", "state_key", "type"]
  defp strip(event), do: Map.take(event, @stripped_keys)
end
