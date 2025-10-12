defmodule RadioBeam.Room.Sync do
  alias RadioBeam.Repo
  alias RadioBeam.PDU
  alias RadioBeam.PubSub
  alias RadioBeam.Room
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.Room.Sync.Core
  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.Room.Sync
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.User
  alias RadioBeam.User.EventFilter

  defstruct ~w|user device_id filter start room_ids known_memberships full_state? timeout functions|a

  @opaque t() :: %__MODULE__{}

  # TODO: make configurable?
  @task_concurrency 5
  @task_timeout :timer.seconds(15)
  @task_opts [
    timeout: @task_timeout,
    on_timeout: :kill_task,
    max_concurrency: @task_concurrency
  ]

  def init(user, device_id, opts \\ []) do
    since = Keyword.get(opts, :since)

    filter =
      case Keyword.get(opts, :filter, :none) do
        %EventFilter{} = filter ->
          filter

        filter when is_map(filter) ->
          EventFilter.new(filter)

        :none ->
          EventFilter.new(%{})

        filter_id ->
          case User.get_event_filter(user, filter_id) do
            {:ok, filter} -> filter
            {:error, :not_found} -> EventFilter.new(%{})
          end
      end

    sync_room_id? =
      case filter.rooms do
        {:allowlist, allowlist} -> &(&1 in allowlist)
        {:denylist, denylist} -> &(&1 not in denylist)
        :none -> &Function.identity/1
      end

    # last_sync_pdus_by_room_id =
    #   user.id
    #   |> Room.all_where_has_membership()
    #   |> Stream.filter(sync_room_id?)
    #   |> Map.new(&{&1, :initial})

    # last_sync_pdus_by_room_id =
    #   case since do
    #     nil ->
    #       last_sync_pdus_by_room_id

    #     %{event_ids: event_ids} ->
    #       {:ok, pdus} = Repo.get_all(PDU, event_ids)
    #       Enum.reduce(pdus, last_sync_pdus_by_room_id, &Map.replace(&2, &1.room_id, &1))
    #   end

    get_room_ids_with_membership =
      Keyword.get(opts, :get_room_ids_to_sync, &Room.all_where_has_membership/1)

    room_ids =
      user.id
      |> get_room_ids_with_membership.()
      |> Stream.filter(sync_room_id?)
      |> MapSet.new()

    %__MODULE__{
      user: user,
      device_id: device_id,
      filter: filter,
      start: since,
      room_ids: room_ids,
      known_memberships: LazyLoadMembersCache.get(room_ids, device_id),
      full_state?: Keyword.get(opts, :full_state?, false),
      timeout: Keyword.get(opts, :timeout, 0),
      functions: %{
        event_stream: &Room.View.timeline_event_stream(&1, user.id, :tip),
        get_events_for_user: &Room.View.get_events(&1, user.id, &2),
        order_id_to_event_id: &Room.View.order_id_to_event_id/2
      }
    }
  end

  def perform(%__MODULE__{} = sync) do
    PubSub.subscribe(PubSub.invite_events(sync.user.id))
    for room_id <- sync.room_ids, do: PubSub.subscribe(PubSub.all_room_events(room_id))

    # read any events that occurred since the last sync
    sync_result =
      sync.room_ids
      |> Task.async_stream(&perform(sync, &1), @task_opts)
      |> Enum.reduce(Sync.Result.new(), fn {:ok, {room_sync_result, room_id, maybe_next_batch_order_id}}, sync_result ->
        Sync.Result.put_result(sync_result, room_sync_result, room_id, maybe_next_batch_order_id)
      end)

    # no new visible events since last sync? read room events as they arrive in
    # the mailbox, up until the timeout or we get one that we can show
    # TODO: sync_result |> wait_if_empty |> side_effects
    sync_result =
      if Enum.empty?(sync_result.data) do
        sync.timeout
        |> wait_for_room_events()
        |> Stream.filter(fn
          {:room_event, %PDU{room_id: room_id}} -> room_id in sync.room_ids
          # invited to a new room? it won't be in sync.room_ids, let it through
          {:room_invite, room_id} -> room_id
        end)
        |> Enum.reduce_while(sync_result, fn
          {:room_event, %PDU{} = pdu}, sync_result ->
            {room_sync_result, room_id, maybe_next_batch_order_id} =
              sync.functions.event_stream
              |> put_in(fn _room_id -> [pdu] end)
              |> perform(pdu.room_id)

            case Sync.Result.put_result(sync_result, room_sync_result, room_id, maybe_next_batch_order_id) do
              %Sync.Result{data: []} = sync_result -> {:cont, sync_result}
              %Sync.Result{data: [_ | _]} = sync_result -> {:halt, sync_result}
            end

          {:room_invite, room_id}, sync_result ->
            sync = put_in(sync.functions.event_stream, fn _room_id -> [] end)
            sync = update_in(sync.room_ids, &MapSet.put(&1, room_id))

            {room_sync_result, room_id, maybe_next_batch_order_id} = perform(sync, room_id)

            case Sync.Result.put_result(sync_result, room_sync_result, room_id, maybe_next_batch_order_id) do
              %Sync.Result{data: []} = sync_result -> {:cont, sync_result}
              %Sync.Result{data: [_ | _]} = sync_result -> {:halt, sync_result}
            end
        end)
      else
        sync_result
      end

    sync_result.data
    |> Stream.filter(&match?(%JoinedRoomResult{}, &1))
    |> Stream.map(&{&1.room_id, &1.sender_ids |> MapSet.delete(sync.user.id) |> MapSet.to_list()})
    |> Enum.each(fn {room_id, sender_ids} -> LazyLoadMembersCache.put(sync.device_id, room_id, sender_ids) end)

    sync_result
  end

  @spec perform(t(), Room.id()) :: :no_update | JoinedRoomResult.t() | InvitedRoomResult.t()
  defp perform(%__MODULE__{} = sync, room_id) do
    with {:ok, room} <- Repo.fetch(Room, room_id) do
      room_sync_result = Core.perform(sync, room)

      maybe_next_batch_order_id =
        case room_sync_result do
          # invites from ignored users will return :no_update, and won't have a next_batch_pdu
          :no_update -> use_last_sync_order_id_or_nil(sync.start, room_id)
          %JoinedRoomResult{latest_order_id: order_id} -> order_id
          %InvitedRoomResult{} -> Room.View.get_latest_order_id!(room_id)
        end

      {room_sync_result, room_id, maybe_next_batch_order_id}
    end
  end

  defp use_last_sync_order_id_or_nil(nil, _room_id), do: nil

  defp use_last_sync_order_id_or_nil(%PaginationToken{} = since, room_id) do
    case PaginationToken.room_last_seen_order_id(since, room_id) do
      {:ok, %TopologicalID{} = order_id} -> order_id
      {:error, :not_found} -> nil
    end
  end

  defp wait_for_room_events(timeout) do
    Stream.resource(
      fn -> timeout end,
      fn timeout ->
        time_before_receive = :os.system_time(:millisecond)

        receive do
          message ->
            remaining_timeout = max(0, timeout - (:os.system_time(:millisecond) - time_before_receive))

            case message do
              {:room_event, %PDU{}} = room_event_message -> {[room_event_message], remaining_timeout}
              {:room_invite, "!" <> _} = room_invite_message -> {[room_invite_message], remaining_timeout}
              _ -> {[], remaining_timeout}
            end
        after
          timeout -> {:halt, :no_update}
        end
      end,
      &Function.identity/1
    )
  end
end
