defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  require Logger

  alias Phoenix.PubSub
  alias RadioBeam.Room.Timeline.Core
  alias RadioBeam.Room.Timeline.Filter
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.PDU
  alias RadioBeam.PubSub, as: PS
  alias RadioBeam.Room

  @attrs ~w|events sync|a
  @enforce_keys @attrs
  defstruct @attrs
  @type t() :: %__MODULE__{events: [PDU.t()], sync: {:partial, prev_batch_token()} | :complete}

  @type prev_batch_token() :: String.t()

  defimpl Jason.Encoder do
    def encode(%{sync: {:partial, prev_batch}} = timeline, opts) do
      Jason.Encode.map(%{events: timeline.events, limited: true, prev_batch: prev_batch}, opts)
    end

    def encode(%{sync: :complete} = timeline, opts) do
      Jason.Encode.map(%{events: timeline.events, limited: false}, opts)
    end
  end

  def complete(events), do: %__MODULE__{events: events, sync: :complete}
  def partial(events, token), do: %__MODULE__{events: events, sync: {:partial, token}}

  def get_messages(room_id, user_id, device_id, direction, from, to, opts \\ [])

  def get_messages(%Room{} = room, user_id, device_id, direction, from, to, opts) do
    from_event_ids = parse_message_window_boundary(from, room, direction)
    to_event_ids = parse_message_window_boundary(to, room, direction)

    order =
      case direction do
        :forward -> :ascending
        :backward -> :descending
      end

    filter = Keyword.get_lazy(opts, :filter, fn -> Filter.parse(%{}) end)
    # TODO...there's possibly a :limit opt passed too, but the filter 
    # also has limiting capabilities???

    latest_joined_at_depth = Room.users_latest_join_depth(room.id, user_id)

    ignore_memberships_from =
      if filter.state.memberships == :lazy do
        known_membership_map = LazyLoadMembersCache.get([room.id], device_id)
        Map.get(known_membership_map, room.id, [])
      else
        []
      end

    %__MODULE__{} =
      timeline = timeline(room.id, user_id, from_event_ids, to_event_ids, filter, latest_joined_at_depth, order)

    keys_to_take = timeline |> Core.all_sender_ids(except: ignore_memberships_from) |> Enum.map(&{"m.room.member", &1})
    members = room.state |> Map.take(keys_to_take) |> Map.values()
    events = timeline.events |> Enum.reverse() |> Core.format(filter, room.version)

    case timeline.sync do
      {:partial, prev_batch} ->
        %{chunk: events, state: members, start: from, end: prev_batch}

      :complete ->
        %{chunk: events, state: members, start: from}
    end
  end

  def get_messages(room_id, user_id, device_id, direction, from, to, opts) do
    case Memento.transaction(fn -> Memento.Query.read(Room, room_id) end) do
      {:ok, %Room{state: %{{"m.room.member", ^user_id} => %{"content" => %{"membership" => "join"}}}} = room} ->
        {:ok, get_messages(room, user_id, device_id, direction, from, to, opts)}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp parse_message_window_boundary("batch:" <> _ = token, _room, _dir), do: Core.decode_since_token(token)
  defp parse_message_window_boundary(:limit, room, :forward), do: room.latest_event_ids
  defp parse_message_window_boundary(:limit, _room, :backward), do: []
  defp parse_message_window_boundary(:first, _room, :forward), do: []
  defp parse_message_window_boundary(:last, room, :backward), do: room.latest_event_ids

  def max_events(type) when type in [:timeline, :state] do
    Application.get_env(:radio_beam, :max_events)[type]
  end

  @init_rooms_acc {%{join: %{}, invite: %{}, knock: %{}, leave: %{}}, _config_map = %{}, _event_ids = []}
  def sync(room_ids, user_id, device_id, opts \\ []) do
    filter = Keyword.get_lazy(opts, :filter, fn -> Filter.parse(%{}) end)

    room_ids =
      case filter.rooms do
        {:allowlist, allowlist} -> Enum.filter(room_ids, &(&1 in allowlist))
        {:denylist, denylist} -> Enum.reject(room_ids, &(&1 in denylist))
        :none -> room_ids
      end

    last_sync_rooms_to_pdus_map = opts |> Keyword.get(:since, :latest) |> parse_since_token()
    known_membership_map = LazyLoadMembersCache.get(room_ids, device_id)

    PubSub.subscribe(PS, PS.invite_events(user_id))

    {rooms_sync, config_map, event_ids} =
      Enum.reduce(room_ids, @init_rooms_acc, fn room_id, {sync_acc, configs, event_ids} ->
        last_sync_pdus = Map.get(last_sync_rooms_to_pdus_map, room_id, :none)
        known_memberships = Map.get(known_membership_map, room_id, MapSet.new())

        case sync_one(room_id, user_id, last_sync_pdus, known_memberships, opts) do
          {:ok, tl_config, sync_result} ->
            LazyLoadMembersCache.put(device_id, room_id, Core.all_sender_ids(sync_result, except: [user_id]))

            {put_in(sync_acc, [tl_config.room_sync_type, room_id], sync_result), Map.put(configs, room_id, tl_config),
             tl_config.sync_event_ids ++ event_ids}

          {:ok, room_sync_type, sync_event_ids, sync_result} ->
            {put_in(sync_acc, [room_sync_type, room_id], sync_result), configs, sync_event_ids ++ event_ids}

          {:no_update, tl_config} when is_map(tl_config) ->
            {sync_acc, Map.put(configs, room_id, tl_config), tl_config.sync_event_ids ++ event_ids}

          {:no_update, sync_event_ids} ->
            {sync_acc, configs, sync_event_ids ++ event_ids}

          :noop ->
            {sync_acc, configs, event_ids}
        end
      end)

    {rooms_sync, event_ids} =
      if Enum.all?(rooms_sync, fn {_, map} -> map_size(map) == 0 end) do
        timeout = Keyword.get(opts, :timeout, 0)

        case await_updates_until_timeout(config_map, event_ids, user_id, timeout) do
          :timeout -> {rooms_sync, event_ids}
          res -> res
        end
      else
        {rooms_sync, event_ids}
      end

    %{
      rooms: rooms_sync,
      next_batch: Core.encode_since_token(event_ids)
    }
  end

  defp sync_one(room_id, user_id, last_sync_pdus, known_memberships, opts) do
    filter = Keyword.get_lazy(opts, :filter, fn -> Filter.parse(%{}) end)

    membership =
      case Room.get_membership(room_id, user_id) do
        %{"content" => %{"membership" => membership}} -> membership
        :not_found -> :not_found
      end

    case membership do
      "leave" when not filter.include_leave? ->
        {:ok, room} = Room.get(room_id)
        {:no_update, room.latest_event_ids}

      membership when membership in ~w|ban join leave| ->
        full_state? = Keyword.get(opts, :full_state?, false)

        timeline_config =
          make_config(room_id, user_id, membership, last_sync_pdus, filter, full_state?, known_memberships)

        case Core.sync_timeline(timeline_config, user_id) do
          :no_update -> {:no_update, timeline_config}
          timeline -> {:ok, timeline_config, timeline}
        end

      # TODO: should the invite reflect changes to stripped state events that
      # happened after the invite?
      "invite" when last_sync_pdus == :none ->
        PubSub.subscribe(PS, PS.stripped_state_events(room_id))
        {:ok, room} = Room.get(room_id)
        {:ok, :invite, room.latest_event_ids, %{invite_state: %{events: Room.stripped_state(room)}}}

      "invite" ->
        {:no_update, Enum.map(last_sync_pdus, & &1.event_id)}

      "knock" ->
        # TOIMPL
        {:no_update, []}

      :not_found ->
        :noop
    end
  end

  defp make_config(room_id, user_id, membership, last_sync_pdus, filter, full_state?, known_memberships) do
    last_sync_event_ids = if last_sync_pdus == :none, do: [], else: Enum.map(last_sync_pdus, & &1.event_id)

    case membership do
      "join" ->
        PubSub.subscribe(PS, PS.all_room_events(room_id))
        {:ok, room} = Room.get(room_id)

        %{
          event_producer: &timeline(room_id, user_id, room.latest_event_ids, last_sync_event_ids, &1, room.depth),
          filter: filter,
          full_state?: full_state?,
          last_sync_pdus: last_sync_pdus,
          latest_joined_depth: room.depth,
          room: room,
          room_sync_type: :join,
          known_memberships: known_memberships,
          sync_event_ids: room.latest_event_ids
        }

      membership when membership in ~w|ban leave| ->
        {:ok, room} = Room.get(room_id)
        user_leave_event_id = room.state[{"m.room.member", user_id}]["event_id"]
        {:ok, pdu} = PDU.get(user_leave_event_id)

        %{
          event_producer: &timeline(room_id, user_id, [user_leave_event_id], last_sync_event_ids, &1, pdu.depth - 1),
          filter: filter,
          full_state?: full_state?,
          last_sync_pdus: last_sync_pdus,
          latest_joined_depth: pdu.depth - 1,
          room: room,
          room_sync_type: :leave,
          known_memberships: known_memberships,
          sync_event_ids: [user_leave_event_id]
        }
    end
  end

  defp await_updates_until_timeout(config_map, event_ids, user_id, timeout) do
    time_before_wait = :os.system_time(:millisecond)

    receive do
      {msg_type, _, _} = msg when msg_type in ~w|room_event room_stripped_state room_invite|a ->
        rem_timeout = max(0, timeout - (:os.system_time(:millisecond) - time_before_wait))

        case Core.handle_room_message(msg, config_map, user_id) do
          :keep_waiting -> await_updates_until_timeout(config_map, event_ids, user_id, rem_timeout)
          {rooms_sync, sync_event_ids} -> {rooms_sync, sync_event_ids ++ event_ids}
        end
    after
      timeout -> :timeout
    end
  end

  defp parse_since_token(:latest), do: %{}

  defp parse_since_token(since) do
    {:ok, pdus} = since |> Core.decode_since_token() |> PDU.all()
    Enum.group_by(pdus, & &1.room_id)
  end

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
        complete(timeline)

      {:ok, {next_event, timeline}} ->
        event_ids = if order == :descending, do: [next_event.event_id], else: next_event.prev_events
        partial(timeline, Core.encode_since_token(event_ids))

      {:error, error} ->
        Logger.error("tried to fetch a timeline of events for #{inspect(user_id)}, but got error: #{inspect(error)}")
        complete([])
    end
  end
end
