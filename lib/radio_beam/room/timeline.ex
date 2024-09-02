defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  import RadioBeam.Room.Timeline.Utils

  require Logger

  alias Phoenix.PubSub
  alias RadioBeam.Room.Timeline.Filter
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
        events = events |> Enum.reverse() |> format(filter, room.version)
        # TOIMPL: add support for lazy_load_members and include_redundant_members
        %{chunk: events, state: MapSet.to_list(members), start: from, end: prev_batch}

      %{limited: false, events: events} ->
        members = MapSet.new(events, &Map.fetch!(room.state, {"m.room.member", &1.sender}))
        events = events |> Enum.reverse() |> format(filter, room.version)
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

  defp parse_token("batch:" <> _ = token, _room, _dir), do: decode_since_token(token)
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

    room_ids =
      case filter.rooms do
        {:allowlist, allowlist} -> Enum.filter(room_ids, &(&1 in allowlist))
        {:denylist, denylist} -> Enum.reject(room_ids, &(&1 in denylist))
        :none -> room_ids
      end

    for room_id <- room_ids, do: PubSub.subscribe(PS, PS.all_room_events(room_id))
    {:ok, rooms} = Room.all(room_ids)

    {rooms_sync, event_ids} =
      rooms
      |> sync_rooms(user_id, opts)
      |> await_if_no_updates(rooms, user_id, opts)

    %{
      rooms: rooms_sync,
      next_batch: encode_since_token(event_ids)
    }
  end

  @init_rooms_acc {%{join: %{}, invite: %{}, knock: %{}, leave: %{}}, _event_ids = []}
  defp sync_rooms(rooms, user_id, opts) do
    since = Keyword.get(opts, :since, :latest)
    filter = Keyword.get(opts, :filter, %{})
    last_sync_event_map = parse_since_token(since)

    Enum.reduce(
      rooms,
      @init_rooms_acc,
      &sync_room(&1, user_id, last_sync_event_map, filter.include_leave?, &2, opts)
    )
  end

  defp sync_room(room, user_id, last_sync_event_map, include_leave?, {rooms, event_ids}, opts) do
    %Room{id: room_id} = room

    membership = get_in(room.state, [{"m.room.member", user_id}, "content", "membership"])

    case get_sync_limit_by_membership(room, user_id, membership, last_sync_event_map, include_leave?) do
      {:limit, room_type, latest_join_depth, latest_event_ids} ->
        opts = Keyword.put(opts, :latest_joined_at_depth, latest_join_depth)
        stop_at_any = Map.get(last_sync_event_map, room.id, [])

        rooms =
          case sync_room_timeline(room, user_id, latest_event_ids, stop_at_any, opts) do
            :no_update -> rooms
            room_update -> put_in(rooms, [room_type, room_id], room_update)
          end

        {rooms, latest_event_ids ++ event_ids}

      :invite ->
        {put_in(rooms, [:invite, room_id], invited_room_sync(room)), room.latest_event_ids ++ event_ids}

      :knock ->
        Logger.info("TOIMPL: sync with knock rooms")
        {rooms, event_ids}

      :none ->
        {rooms, room.latest_event_ids ++ event_ids}
    end
  end

  defp get_sync_limit_by_membership(room, user_id, membership, last_sync_event_map, include_leave?) do
    case membership do
      "join" ->
        {:limit, :join, room.depth, room.latest_event_ids}

      # TODO: should the invite reflect changes to stripped state events that
      # happened after the invite?
      "invite" when is_map_key(last_sync_event_map, room.id) ->
        :none

      "invite" ->
        :invite

      "knock" ->
        :knock

      "leave" when not include_leave? ->
        :none

      "leave" ->
        user_leave_event_id = room.state[{"m.room.member", user_id}]["event_id"]
        {:ok, pdu} = PDU.get(user_leave_event_id)
        {:limit, :leave, pdu.depth - 1, [user_leave_event_id]}
    end
  end

  defp await_if_no_updates({rooms_sync, event_ids}, rooms, user_id, opts) do
    if Enum.all?(rooms_sync, fn {_, map} -> map_size(map) == 0 end) do
      timeout = Keyword.get(opts, :timeout, 0)

      # TODO - only scanning for join rooms rn, will probably want to listen for
      # new invites, knocks, etc. too
      interested_room_ids =
        for room <- rooms,
            room.state[{"m.room.member", user_id}]["content"]["membership"] == "join",
            into: MapSet.new(),
            do: room.id

      case await_next_event(interested_room_ids, user_id, timeout) do
        :timeout ->
          {rooms_sync, event_ids}

        {:update, room_id, rem_timeout} ->
          opts = Keyword.put(opts, :timeout, rem_timeout)
          {:ok, room} = Room.get(room_id)

          [room]
          |> sync_rooms(user_id, opts)
          |> await_if_no_updates(rooms, user_id, opts)
      end
    else
      {rooms_sync, event_ids}
    end
  end

  defp await_next_event(interested_room_ids, user_id, timeout) do
    time_before_wait = :os.system_time(:millisecond)

    receive do
      {:room_update, room_id} ->
        new_timeout = max(0, timeout - (:os.system_time(:millisecond) - time_before_wait))

        if room_id in interested_room_ids do
          {:update, room_id, new_timeout}
        else
          await_next_event(interested_room_ids, user_id, new_timeout)
        end
    after
      timeout -> :timeout
    end
  end

  defp parse_since_token(:latest), do: %{}

  defp parse_since_token(since) do
    {:ok, pdus} = since |> decode_since_token() |> PDU.all()
    Enum.group_by(pdus, & &1.room_id, & &1.event_id)
  end

  @spec sync_room_timeline(Room.t(), String.t(), list(), list(), keyword()) :: map() | :no_update
  defp sync_room_timeline(room, user_id, event_ids, stop_at_any, opts) do
    full_state? = Keyword.get(opts, :full_state?, false)
    filter = Keyword.get(opts, :filter, %{})
    latest_joined_at_depth = Keyword.get(opts, :latest_joined_at_depth, -1)

    timeline = timeline(room.id, user_id, event_ids, stop_at_any, filter, latest_joined_at_depth)

    oldest_event = List.first(timeline.events)

    if is_nil(oldest_event) and not full_state? do
      :no_update
    else
      {tl_events, state_delta} =
        cond do
          not allowed_room?(room.id, filter.state.rooms) ->
            {[], []}

          not Keyword.has_key?(opts, :since) or full_state? ->
            senders = get_tl_senders(timeline.events, user_id)
            {timeline.events, state_delta(nil, oldest_event, filter.state, room.version, senders)}

          :else ->
            senders = get_tl_senders(timeline.events, user_id)
            {timeline.events, state_delta(List.last(stop_at_any), oldest_event, filter.state, room.version, senders)}
        end

      if Enum.empty?(state_delta) and Enum.empty?(tl_events) do
        :no_update
      else
        %{
          # TODO: I think the event format needs to apply to state events here too? 
          state: state_delta,
          timeline: %{timeline | events: format(tl_events, filter, room.version)}
        }
      end
    end
  end

  defp get_tl_senders(events, user_id) do
    events
    |> MapSet.new(& &1.sender)
    |> MapSet.put(user_id)
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
        event_ids = if order == :descending, do: [next_event.event_id], else: next_event.prev_events
        %{limited: true, events: timeline, prev_batch: encode_since_token(event_ids)}

      {:error, error} ->
        Logger.error("tried to fetch a timeline of events for #{inspect(user_id)}, but got error: #{inspect(error)}")
        %{limited: false, events: []}
    end
  end

  defp format(timeline, filter, room_version) do
    format = String.to_existing_atom(filter.format)
    Enum.map(timeline, &(&1 |> PDU.to_event(room_version, :strings, format) |> Filter.take_fields(filter.fields)))
  end

  defp state_delta(nil, tl_start_event, filter, _room_version, senders) do
    tl_start_event.prev_state
    |> Stream.map(fn {_, event} -> event end)
    |> Enum.filter(&passes_filter?(&1, filter, senders))
  end

  defp state_delta(last_sync_event_id, tl_start_event, filter, room_version, senders) do
    {:ok, last_sync_event} = PDU.get(last_sync_event_id)

    old_state =
      if is_nil(last_sync_event.state_key) do
        last_sync_event.prev_state
      else
        event = PDU.to_event(last_sync_event, room_version, :strings)
        Map.put(last_sync_event.prev_state, {last_sync_event.type, last_sync_event.state_key}, event)
      end

    for {k, %{"event_id" => cur_event_id} = cur_event} <- tl_start_event.prev_state, reduce: [] do
      acc ->
        case get_in(old_state, [k, "event_id"]) do
          ^cur_event_id ->
            acc

          _cur_event_id_or_nil ->
            if passes_filter?(cur_event, filter, senders) do
              [cur_event | acc]
            else
              acc
            end
        end
    end
  end

  defp passes_filter?(event, filter, senders) do
    (not filter.lazy_load_members or event["sender"] in senders) and
      :radio_beam_room_queries.passes_filter(filter, event["type"], event["sender"], event["content"])
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
