defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  require Logger

  alias Phoenix.PubSub
  alias RadioBeam.PDU
  alias RadioBeam.PubSub, as: PS
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.Room.EventGraph.PaginationToken
  alias RadioBeam.Room.Timeline.Core
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room
  alias RadioBeam.User.EventFilter

  @attrs ~w|events sync|a
  @enforce_keys @attrs
  defstruct @attrs
  @type t() :: %__MODULE__{events: [PDU.t()], sync: PaginationToken.t() | :complete}

  defimpl Jason.Encoder do
    def encode(%{sync: :complete} = timeline, opts) do
      Jason.Encode.map(%{events: timeline.events, limited: false}, opts)
    end

    def encode(%{sync: token} = timeline, opts) do
      Jason.Encode.map(%{events: timeline.events, limited: true, prev_batch: PaginationToken.encode(token)}, opts)
    end
  end

  def complete(events), do: %__MODULE__{events: events, sync: :complete}
  def partial(events, token), do: %__MODULE__{events: events, sync: token}

  # shorthand to filter a single PDU instead of a list
  def authz_to_view?(pdu, user_id), do: not Enum.empty?(filter_authz([pdu], user_id))

  def filter_authz([], _dir, _user_id), do: []
  def filter_authz(pdus, :backward, user_id), do: pdus |> Enum.reverse() |> filter_authz(user_id)
  def filter_authz(pdus, :forward, user_id), do: pdus |> filter_authz(user_id) |> Enum.reverse()

  defp filter_authz([first_pdu | _] = pdus, user_id) do
    {:ok, state_events} = PDU.all(first_pdu.state_events)

    user_membership =
      Enum.find_value(state_events, :not_found, fn
        %{type: "m.room.member", state_key: ^user_id} = pdu -> pdu.content["membership"]
        _ -> false
      end)

    user_joined_later? = EventGraph.user_joined_after?(user_id, first_pdu.room_id, List.last(pdus))

    Core.filter_authz(pdus, user_id, user_membership, user_joined_later?)
  end

  def get_messages(room_id, user_id, device_id, from_and_direction, to, opts \\ [])

  def get_messages(%Room{} = room, user_id, device_id, from_and_direction, to, opts) do
    filter =
      Keyword.get_lazy(opts, :filter, fn ->
        case Keyword.get(opts, :limit, :none) do
          :none -> EventFilter.new(%{})
          limit -> EventFilter.new(%{"room" => %{"timeline" => %{"limit" => limit}}})
        end
      end)

    direction =
      case from_and_direction do
        :root -> :forward
        :tip -> :backward
        {_from, dir} when dir in [:forward, :backward] -> dir
      end

    response =
      case EventGraph.traverse(room.id, from_and_direction, to, filter.timeline.limit) do
        {:ok, pdus, :root} -> %{chunk: pdus}
        {:ok, pdus, :tip} -> %{chunk: pdus}
        {:ok, pdus, {:more, token}} -> %{chunk: pdus, end: token}
        # TODO: sync initiate backfill job
        {:ok, [], {:end_of_chunk, _token}} -> :block_until_rec_events
        # TODO: async initiate backfill job
        {:ok, pdus, {:end_of_chunk, token}} -> %{chunk: pdus, end: token}
        # TODO: sync initiate backfill job
        :missing_events -> :block_until_rec_events
      end

    response
    |> Map.update!(:chunk, &filter_authz(&1, direction, user_id))
    |> Map.update!(:chunk, &bundle_aggregations(&1, user_id))
    # TODO update the 2 fxns below to take the `Core.format` events
    |> put_member_state(room, device_id, filter)
    |> put_start_token(from_and_direction, direction)
    |> Map.update!(:chunk, &Core.format(&1, filter, room.version))
    |> then(&{:ok, &1})
  end

  def get_messages(room_id, user_id, device_id, from_and_direction, to, opts) do
    with event when event != :not_found <- Room.get_membership(room_id, user_id),
         {:ok, %Room{} = room} <- Room.get(room_id) do
      get_messages(room, user_id, device_id, from_and_direction, to, opts)
    else
      _ ->
        {:error, :unauthorized}
    end
  end

  defp put_start_token(response, {%PaginationToken{} = from, _dir}, _inferred_dir), do: Map.put(response, :start, from)

  defp put_start_token(%{chunk: [start_pdu | _]} = response, _root_or_tip, dir),
    do: Map.put(response, :start, PaginationToken.new(start_pdu, dir))

  # in practice this should basically never be hit, unless someone's trying to
  # get events they don't have access to see, in which case not included the
  # required `start` field is not a big deal
  defp put_start_token(response, _root_or_tip, _dir), do: response

  defp put_member_state(%{chunk: events} = response, room, device_id, filter) do
    ignore_memberships_from =
      if filter.state.memberships == :lazy do
        known_membership_map = LazyLoadMembersCache.get([room.id], device_id)
        Map.get(known_membership_map, room.id, [])
      else
        []
      end

    desired_state_keys =
      events |> Core.all_sender_ids(except: ignore_memberships_from) |> Enum.map(&{"m.room.member", &1})

    members = room.state |> Map.take(desired_state_keys) |> Map.values()

    Map.put(response, :state, members)
  end

  @init_rooms_acc {%{join: %{}, invite: %{}, knock: %{}, leave: %{}}, _config_map = %{}, _latest_pdus = []}
  def sync(room_ids, user_id, device_id, opts \\ []) do
    filter = Keyword.get_lazy(opts, :filter, fn -> EventFilter.new(%{}) end)

    room_ids =
      case filter.rooms do
        {:allowlist, allowlist} -> Enum.filter(room_ids, &(&1 in allowlist))
        {:denylist, denylist} -> Enum.reject(room_ids, &(&1 in denylist))
        :none -> room_ids
      end

    last_sync_rooms_to_pdus_map = opts |> Keyword.get(:since, :latest) |> get_pagination_token_pdus()
    known_membership_map = LazyLoadMembersCache.get(room_ids, device_id)

    PubSub.subscribe(PS, PS.invite_events(user_id))

    {rooms_sync, config_map, latest_pdus} =
      Enum.reduce(room_ids, @init_rooms_acc, fn room_id, {sync_acc, configs, latest_pdus} ->
        last_sync_pdus = Map.get(last_sync_rooms_to_pdus_map, room_id)
        known_memberships = Map.get(known_membership_map, room_id, MapSet.new())

        case sync_one(room_id, user_id, last_sync_pdus, known_memberships, opts) do
          {:ok, sync_config, sync_result} ->
            LazyLoadMembersCache.put(device_id, room_id, Core.all_sender_ids(sync_result, except: [user_id]))

            {put_in(sync_acc, [sync_config.room_sync_type, room_id], sync_result),
             Map.put(configs, room_id, sync_config), sync_config.sync_pdus ++ latest_pdus}

          {:ok, room_sync_type, sync_pdus, sync_result} ->
            {put_in(sync_acc, [room_sync_type, room_id], sync_result), configs, sync_pdus ++ latest_pdus}

          {:no_update, sync_config} when is_map(sync_config) ->
            {sync_acc, Map.put(configs, room_id, sync_config), sync_config.sync_pdus ++ latest_pdus}

          {:no_update, sync_pdus} ->
            {sync_acc, configs, sync_pdus ++ latest_pdus}

          :noop ->
            {sync_acc, configs, latest_pdus}
        end
      end)

    {rooms_sync, latest_pdus_or_ts} =
      if Enum.all?(rooms_sync, fn {_, map} -> map_size(map) == 0 end) do
        timeout = Keyword.get(opts, :timeout, 0)

        case await_updates_until_timeout(config_map, latest_pdus, user_id, timeout) do
          {:timeout, fallback_last_sync_ts} -> {rooms_sync, ([] == latest_pdus && fallback_last_sync_ts) || latest_pdus}
          res -> res
        end
      else
        {rooms_sync, latest_pdus}
      end

    %{
      rooms: rooms_sync,
      next_batch: PaginationToken.new(latest_pdus_or_ts, :forward)
    }
  end

  defp sync_one(room_id, user_id, last_sync_pdus, known_memberships, opts) do
    filter = Keyword.get_lazy(opts, :filter, fn -> EventFilter.new(%{}) end)

    membership =
      case Room.get_membership(room_id, user_id) do
        %{"content" => %{"membership" => membership}} -> membership
        :not_found -> :not_found
      end

    case membership do
      "leave" when not filter.include_leave? ->
        {:ok, room} = Room.get(room_id)
        {:ok, latest_pdus} = PDU.all(room.latest_event_ids)
        {:no_update, latest_pdus}

      membership when membership in ~w|ban join leave| ->
        full_state? = Keyword.get(opts, :full_state?, false)

        %__MODULE__{} = timeline = timeline(room_id, user_id, filter, opts)
        {:ok, state_delta_pdus} = get_state_delta(last_sync_pdus, timeline.events, full_state?)

        sync_config = make_config(room_id, user_id, membership, filter, full_state?, known_memberships)

        case Core.sync_timeline(timeline, state_delta_pdus, user_id, sync_config) do
          :no_update -> {:no_update, sync_config}
          timeline -> {:ok, sync_config, timeline}
        end

      # TODO: should the invite reflect changes to stripped state events that
      # happened after the invite?
      "invite" when is_nil(last_sync_pdus) ->
        PubSub.subscribe(PS, PS.stripped_state_events(room_id))
        {:ok, room} = Room.get(room_id)
        {:ok, latest_pdus} = PDU.all(room.latest_event_ids)
        {:ok, :invite, latest_pdus, %{invite_state: %{events: Room.stripped_state(room, user_id)}}}

      "invite" ->
        {:no_update, last_sync_pdus}

      "knock" ->
        # TOIMPL
        {:no_update, []}

      :not_found ->
        :noop
    end
  end

  defp get_state_delta(last_sync_pdus, timeline_events, full_state?) do
    List.last(last_sync_pdus || [])
    |> Core.get_state_delta_ids(List.first(timeline_events), full_state?)
    |> PDU.all()
  end

  defp make_config(room_id, user_id, membership, filter, full_state?, known_memberships) do
    init_config =
      %{
        filter: filter,
        full_state?: full_state?,
        known_memberships: known_memberships
      }

    case membership do
      "join" ->
        PubSub.subscribe(PS, PS.all_room_events(room_id))
        {:ok, room} = Room.get(room_id)
        {:ok, latest_pdus} = PDU.all(room.latest_event_ids)

        Map.merge(init_config, %{
          room: room,
          room_sync_type: :join,
          sync_pdus: latest_pdus
        })

      membership when membership in ~w|ban leave| ->
        {:ok, room} = Room.get(room_id)
        user_leave_event_id = room.state[{"m.room.member", user_id}]["event_id"]
        {:ok, user_leave_pdu} = PDU.get(user_leave_event_id)

        Map.merge(init_config, %{
          room: room,
          room_sync_type: :leave,
          sync_pdus: [user_leave_pdu]
        })
    end
  end

  defp timeline(room_id, user_id, filter, opts) do
    {events, prev_batch_or_none} =
      case Keyword.fetch(opts, :since) do
        :error ->
          case EventGraph.traverse(room_id, :tip, :limit, filter.timeline.limit) do
            {:ok, pdus, :root} -> {Enum.reverse(pdus), :none}
            {:ok, pdus, {:more, token}} -> {Enum.reverse(pdus), token}
            # TODO: sync initiate backfill job
            {:ok, [], {:end_of_chunk, _token}} -> :block_until_rec_events
            # TODO: async initiate backfill job
            {:ok, pdus, {:end_of_chunk, token}} -> {Enum.reverse(pdus), token}
            # TODO: sync initiate backfill job
            :missing_events -> :block_until_rec_events
          end

        {:ok, %PaginationToken{} = since} ->
          case EventGraph.all_since(room_id, since, filter.timeline.limit) do
            {:ok, pdus, _token, _complete? = true} -> {pdus, :none}
            {:ok, pdus, token, _complete? = false} -> {pdus, token}
          end
      end

    case prev_batch_or_none do
      :none -> events |> filter_authz(:forward, user_id) |> bundle_aggregations(user_id) |> complete()
      token -> events |> filter_authz(:forward, user_id) |> bundle_aggregations(user_id) |> partial(token)
    end
  end

  def bundle_aggregations([], _user_id), do: []

  def bundle_aggregations(%PDU{} = pdu, user_id) do
    {:ok, child_pdus} = PDU.get_children(pdu, _recurse = 1)

    case Enum.filter(child_pdus, &authz_to_view?(&1, user_id)) do
      [] -> pdu
      children -> PDU.Relationships.get_aggregations(pdu, user_id, children)
    end
  end

  def bundle_aggregations(events, user_id) do
    {:ok, child_pdus} = PDU.get_children(events, _recurse = 1)
    # this will get expensive!!
    authz_child_pdus = Enum.filter(child_pdus, &authz_to_view?(&1, user_id))
    authz_child_event_ids = authz_child_pdus |> Stream.map(& &1.event_id) |> MapSet.new()
    authz_child_pdu_map = Enum.group_by(authz_child_pdus, & &1.parent_id)

    events
    |> Stream.reject(&(&1.event_id in authz_child_event_ids))
    |> Enum.map(fn pdu ->
      case Map.fetch(authz_child_pdu_map, pdu.event_id) do
        {:ok, children} -> PDU.Relationships.get_aggregations(pdu, user_id, children)
        :error -> pdu
      end
    end)
  end

  defp await_updates_until_timeout(config_map, latest_pdus, user_id, timeout) do
    time_before_wait = :os.system_time(:millisecond)

    receive do
      {msg_type, _, _} = msg when msg_type in ~w|room_event room_stripped_state room_invite|a ->
        rem_timeout = max(0, timeout - (:os.system_time(:millisecond) - time_before_wait))

        case Core.handle_room_message(msg, config_map, user_id) do
          :keep_waiting -> await_updates_until_timeout(config_map, latest_pdus, user_id, rem_timeout)
          {rooms_sync, sync_pdus} -> {rooms_sync, sync_pdus ++ latest_pdus}
        end
    after
      timeout -> {:timeout, time_before_wait}
    end
  end

  defp get_pagination_token_pdus(:latest), do: %{}

  defp get_pagination_token_pdus(%{event_ids: event_ids}) do
    {:ok, pdus} = PDU.all(event_ids)
    Enum.group_by(pdus, & &1.room_id)
  end
end
