defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  require Logger
  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.SyncBatch

  def sync(room_ids, user_id, opts \\ []) do
    # TOIMPL: timeout opt
    {rooms, latest_ids} = sync_with_room_ids(room_ids, user_id, opts)
    {:ok, next_batch} = SyncBatch.put(latest_ids)

    %{
      rooms: rooms,
      next_batch: next_batch,
      # TOIMPL
      account_data: %{},
      device_lists: [],
      device_one_time_keys_count: -1,
      presence: %{},
      to_device: %{}
    }
  end

  @init_rooms_acc {%{join: %{}, invite: %{}, knock: %{}, leave: %{}}, _latest_ids = []}
  defp sync_with_room_ids(room_ids, user_id, opts) do
    since = Keyword.get(opts, :since, :latest)

    last_sync_event_map = parse_since_token(since)

    Enum.reduce(room_ids, @init_rooms_acc, fn room_id, {rooms, latest_ids} ->
      %Room{} = room = Memento.transaction!(fn -> Memento.Query.read(Room, room_id) end)

      case get_in(room.state, [{"m.room.member", user_id}, "content", "membership"]) do
        "join" ->
          stop_at_any = Map.get(last_sync_event_map, room.id, [])

          rooms =
            case joined_room_sync(user_id, room.latest_event_ids, stop_at_any, room.state, opts) do
              :no_update -> rooms
              room_update -> put_in(rooms, [:join, room_id], room_update)
            end

          {rooms, room.latest_event_ids ++ latest_ids}

        "invite" when is_map_key(last_sync_event_map, room_id) ->
          {rooms, room.latest_event_ids ++ latest_ids}

        "invite" ->
          {put_in(rooms, [:invite, room_id], invited_room_sync(room)), room.latest_event_ids ++ latest_ids}

        "knock" ->
          Logger.info("TOIMPL: sync with knock rooms")
          {rooms, latest_ids}

        "leave" ->
          stop_at_any = Map.get(last_sync_event_map, room.id, [])

          user_leave_event_id = room.state[{"m.room.member", user_id}]["event_id"]
          %PDU{} = pdu = Memento.transaction!(fn -> Memento.Query.read(PDU, user_leave_event_id) end)

          rooms =
            case left_room_sync(user_id, [user_leave_event_id], stop_at_any, pdu.prev_state, opts) do
              :no_update -> rooms
              room_update -> put_in(rooms, [:leave, room_id], room_update)
            end

          {rooms, [pdu.event_id | latest_ids]}
      end
    end)
  end

  defp parse_since_token(:latest), do: %{}

  defp parse_since_token(since) do
    case SyncBatch.get(since) do
      {:ok, %SyncBatch{event_ids: event_ids}} ->
        event_ids
        |> PDU.get()
        |> Stream.map(fn {_event_id, pdu} -> pdu end)
        |> Enum.group_by(& &1.room_id, & &1.event_id)

      {:error, error} ->
        Logger.error(
          "error trying to get a sync batch using `since` token #{inspect(since)}: #{inspect(error)}. Doing an inital sync instead"
        )

        parse_since_token(:latest)
    end
  end

  @default_n 25
  @spec joined_room_sync(String.t(), list(), list(), map(), keyword()) :: map() | :no_update
  defp joined_room_sync(user_id, event_ids, stop_at_any, latest_state, opts) do
    max_events = Keyword.get(opts, :max_events, @default_n)
    full_state? = Keyword.get(opts, :full_state?, false)

    timeline = timeline_from(event_ids, stop_at_any, user_id, max_events)
    oldest_event = List.first(timeline.events)

    if is_nil(oldest_event) and not full_state? do
      :no_update
    else
      %{
        state: Map.values((full_state? && latest_state) || oldest_event.prev_state),
        timeline: %{timeline | events: Enum.map(timeline.events, &PDU.to_event/1)},
        # TOIMPL
        account_data: %{},
        ephemeral: %{},
        summary: %{},
        unread_notifications: %{},
        unread_thread_notifications: %{}
      }
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

  # note: as of writing this is 1:1 with join_room_sync. could refactor if 
  # their impls don't diverge
  defp left_room_sync(user_id, event_ids, stop_at_any, latest_state, opts) do
    max_events = Keyword.get(opts, :max_events, @default_n)
    full_state? = Keyword.get(opts, :full_state?, false)

    timeline = timeline_from(event_ids, stop_at_any, user_id, max_events)
    oldest_event = List.first(timeline.events)

    if is_nil(oldest_event) and not full_state? do
      :no_update
    else
      %{
        state: Map.values((full_state? && latest_state) || oldest_event.prev_state),
        timeline: %{timeline | events: Enum.map(timeline.events, &PDU.to_event/1)},
        # TOIMPL
        account_data: %{}
      }
    end
  end

  @stripped_keys ["content", "sender", "state_key", "type"]
  defp strip(event), do: Map.take(event, @stripped_keys)

  defp timeline_from(event_ids, stop_at_any, user_id, n, events \\ [])

  # after taking n events, if there are still ids to expand, we have a previous batch
  defp timeline_from([_ | _] = rem_ids, _stop_at_any, _user_id, 0, events),
    do: %{limited: true, events: events, prev_batch: Enum.join(rem_ids, "|")}

  # if no remaining ids to expand, the timeline is exhaustive since last sync
  defp timeline_from([], _stop_at_any, _user_id, n, events) when n >= 0, do: %{limited: false, events: events}

  defp timeline_from(event_ids, stop_at_any, user_id, n, events) do
    # TODO: filter events by those user_id is allowed to view
    pdu_map = event_ids |> Stream.reject(&(&1 in stop_at_any)) |> Stream.take(n) |> PDU.get()
    pdus = pdu_map |> Stream.map(&elem(&1, 1)) |> Enum.sort_by(& &1.origin_server_ts)

    pdus
    |> Stream.flat_map(fn event -> event.prev_events end)
    |> Stream.uniq()
    |> Enum.to_list()
    |> timeline_from(stop_at_any, user_id, n - map_size(pdu_map), pdus ++ events)
  end
end
