defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  require Logger

  alias RadioBeam.Repo
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.Timeline.Chunk
  alias RadioBeam.Room.Timeline.Core
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.EventFilter

  @doc """
  Get a chunk of `room_id` events visible to the given `user_id`, starting at
  `from`, up to the limit or a provided `to`. The user must have a membership
  event in the room.

  ### Options

  - `filter`: A `User.EventFilter` to apply to returned events.
  - `limit`: If `filter` is not supplied, this will apply a maximum limit of
    events returned. Otherwise the `EventFilter`'s limits will be applied.
  """
  def get_messages(room_id, user_id, device_id, from, opts \\ []) do
    Repo.transaction(fn ->
      with {:ok, user} = Repo.fetch(User, user_id),
           {:ok, %Room{} = room} <- Repo.fetch(Room, room_id),
           :ok <- check_membership(room, user_id),
           {:ok, event_stream} <- Room.View.timeline_event_stream(room.id, from) do
        ignored_user_ids =
          MapSet.new(user.account_data[:global]["m.ignored_user_list"]["ignored_users"] || %{}, &elem(&1, 0))

        filter = get_filter_from_opts(opts, user)

        # an order_id or :none
        to = Keyword.get(opts, :to, :none)

        direction =
          case from do
            :root -> :forward
            :tip -> :backward
            {_from, dir} when dir in [:forward, :backward] -> dir
          end

        [%Event{} = first_event] = Enum.take(event_stream, 1)
        user_membership_at_first_event = get_user_membership_at_event(first_event, room, user_id)

        {:ok, user_latest_known_join_pdu} = Room.get_latest_known_join(room, user_id)

        not_passed_to =
          cond do
            to == :none -> fn _ -> true end
            direction == :forward -> &(TopologicalID.compare(&1, to) != :gt)
            direction == :backward -> &(TopologicalID.compare(&1, to) != :lt)
          end

        {user_event_stream, last_event} =
          event_stream
          |> Core.from_event_stream(
            direction,
            user_id,
            user_membership_at_first_event,
            user_latest_known_join_pdu,
            filter,
            ignored_user_ids
          )
          |> Stream.take(filter.timeline.limit)
          |> Stream.take_while(not_passed_to)
          |> Enum.flat_map_reduce(first_event.order_id, fn
            %Event{} = event, _ -> {[event], event}
          end)

        maybe_next_order_id =
          cond do
            last_event.order_id == to -> :no_more_events
            last_event.type == "m.room.create" and direction == :backward -> :no_more_events
            :else -> last_event.order_id
          end

        # if is_tuple(next_page_info) and stream_ends_at == :end_of_chunk and Enum.empty?(timeline_events) do
        timeline_events =
          if maybe_next_order_id != :no_more_events and Enum.empty?(timeline_events) do
            # TODO: sync initiate backfill job
            {:error, :not_implemented}
          else
            # TODO: async initiate backfill job
            bundle_aggregations(room, user_timeline_events, user_id)
          end

        get_known_memberships_fxn = fn -> LazyLoadMembersCache.get([room.id], device_id) end

        {:ok, Chunk.new(room, timeline_events, maybe_next_order_id, get_known_memberships_fxn, filter)}
      end
    end)
  end

  defp check_membership(room, user_id) do
    case Room.State.fetch(room.state, "m.room.member", user_id) do
      {:ok, _pdu} -> :ok
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  defp get_filter_from_opts(opts, user) do
    case Keyword.get(opts, :filter, :none) do
      filter when is_map(filter) ->
        filter

      :none ->
        case Keyword.get(opts, :limit, :none) do
          :none -> EventFilter.new(%{})
          limit -> EventFilter.new(%{"room" => %{"timeline" => %{"limit" => limit}}})
        end

      filter_id ->
        case User.get_event_filter(user, filter_id) do
          {:ok, filter} -> filter
          {:error, :not_found} -> EventFilter.new(%{})
        end
    end
  end

  defp get_user_membership_at_event(%Event{} = event, room, user_id) do
    %PDU{} = pdu = Room.DAG.fetch!(room.dag, event.id)

    case Room.State.fetch_at(room.state, "m.room.member", user_id, pdu) do
      {:error, :not_found} -> "leave"
      {:ok, %PDU{} = pdu} -> pdu.event.content["membership"]
    end
  end

  def bundle_aggregations(_room, [], _user_id), do: []

  ### TO UPDATE: need to finish impl of  Room.Core.Relationships...
  def bundle_aggregations(%Room{} = room, %Event{} = event, user_id) do
    # {:ok, child_pdus} = EventGraph.get_children(pdu, _recurse = 1)
    child_pdus =
      for event_id <- Room.View.child_events(room.id, event.id) do
        Room.DAG.fetch!(room.dag, event_id)
      end

    # {:ok, user_latest_known_join_pdu} = Room.get_latest_known_join(room, user_id)
    {:ok, user_latest_known_join_pdu} = Room.View.latest_known_join_pdu(room.id, user_id)

    case reject_unauthorized_child_pdus(room, child_pdus, user_id, user_latest_known_join_pdu) do
      [] -> pdu
      children -> PDU.Relationships.get_aggregations(pdu, user_id, children)
    end
  end

  def bundle_aggregations(room, events, user_id) do
    # {:ok, child_pdus} = EventGraph.get_children(events, _recurse = 1)
    child_pdus =
      for event_id <- Room.View.child_events(room.id, event.id) do
        Room.DAG.fetch!(room.dag, event_id)
      end

    # {:ok, user_latest_known_join_pdu} = Room.get_latest_known_join(room, user_id)
    {:ok, user_latest_known_join_pdu} = Room.View.latest_known_join_pdu(room.id, user_id)

    authz_child_pdus = reject_unauthorized_child_pdus(room, child_pdus, user_id, user_latest_known_join_pdu)
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

  # this is quite expensive!
  # TODO: move relations_controller stuff to here/Timeline.Relations - this could/should be a private module
  def reject_unauthorized_child_pdus(room_id, child_pdus, user_id, user_latest_known_join_pdu) do
    Enum.filter(child_pdus, &pdu_visible_to_user?(room_id, &1, user_id, user_latest_known_join_pdu))
  end

  @doc """
  Returns `true` if the given a `t:RadioBeam.PDU` is visible to `user_id`, else
  returns `false`.
  """
  def pdu_visible_to_user?(room, %PDU{} = pdu, user_id, user_latest_known_join) do
    if user_latest_known_join == {:error, :never_joined} do
      pdu.current_visibility == "world_readable"
    else
      pdu_visible_to_user?(room, pdu, user_id, user_latest_known_join)
    end
  end

  defp pdu_visible_to_user?(room, %PDU{} = pdu, user_id, %PDU{} = user_latest_known_join_pdu) do
    {:ok, state_pdus} = Repo.get_all(PDU, pdu.state_events)

    maybe_membership_pdu = Enum.find(state_pdus, &(&1.type == "m.room.member" and &1.state_key == user_id))
    user_membership_at_pdu = get_in(maybe_membership_pdu.content["membership"]) || "leave"
    user_joined_later? = Core.user_joined_later?(pdu, user_latest_known_join_pdu)

    Core.user_authorized_to_view?(pdu, user_id, user_membership_at_pdu, user_joined_later?)
  end
end
