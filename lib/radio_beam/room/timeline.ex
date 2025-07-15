defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  require Logger

  alias RadioBeam.PDU
  alias RadioBeam.Repo
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.Room.EventGraph.PaginationToken
  alias RadioBeam.Room.Timeline.Chunk
  alias RadioBeam.Room.Timeline.Core
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.EventFilter

  @doc """
  Get a chunk of `room_id` events visible to the given `user_id`, from `from`
  to `to`. The user must have a membership event in the room.

  ### Options

  - `filter`: A `User.EventFilter` to apply to returned events.
  - `limit`: If `filter` is not supplied, this will apply a maximum limit of
    events returned. Otherwise the `EventFilter`'s limits will be applied.
  """
  def get_messages(room_id, user_id, device_id, from, to, opts \\ []) do
    Repo.transaction(fn ->
      with {:ok, _event} <- get_membership(room_id, user_id),
           {:ok, user} = Repo.fetch(User, user_id),
           {:ok, %Room{} = room} <- Room.get(room_id),
           {:ok, event_stream, stream_ends_at} <- EventGraph.traverse(room.id, from) do
        ignored_user_ids =
          MapSet.new(user.account_data[:global]["m.ignored_user_list"]["ignored_users"] || %{}, &elem(&1, 0))

        filter = get_filter_from_opts(opts, user)

        direction =
          case from do
            :root -> :forward
            :tip -> :backward
            {_from, dir} when dir in [:forward, :backward] -> dir
          end

        user_membership_at_first_event = event_stream |> Enum.take(1) |> hd() |> get_user_membership_at_pdu(user_id)
        {:ok, user_latest_known_join_pdu} = Room.get_latest_known_join(room, user_id)
        latest_room_event_id = List.last(room.latest_event_ids)

        {timeline_events, next_page_info} =
          event_stream
          |> Core.from_event_stream(
            direction,
            user_id,
            user_membership_at_first_event,
            user_latest_known_join_pdu,
            filter,
            ignored_user_ids
          )
          |> Enum.flat_map_reduce({filter.timeline.limit, nil}, fn
            _should_never_happen, :no_more_events ->
              {:halt, :no_more_events}

            %PDU{event_id: ^to}, {_num_left, %PDU{} = last_pdu} ->
              {:halt, PaginationToken.new(last_pdu, direction)}

            %PDU{type: "m.room.create"}, {0, last_pdu} when direction == :backward ->
              {:halt, PaginationToken.new(last_pdu, :backward)}

            %PDU{type: "m.room.create"} = pdu, {_num_left, _last_pdu} when direction == :backward ->
              {[pdu], :no_more_events}

            _should_never_happen, %PaginationToken{} = token ->
              {:halt, token}

            # we return a PaginationToken here assuming we want to be able to
            # paginate on new events, once they are sent, opposed to returning
            # :no_more_events
            %PDU{event_id: ^latest_room_event_id}, {0, last_pdu} when direction == :forward ->
              {:halt, PaginationToken.new(last_pdu, :forward)}

            %PDU{event_id: ^latest_room_event_id} = pdu, {_num_left, _last_pdu} when direction == :forward ->
              {[pdu], PaginationToken.new(pdu, :forward)}

            _pdu, {0, last_pdu} ->
              {:halt, PaginationToken.new(last_pdu, direction)}

            pdu, {num_left_to_take, _last_pdu} ->
              {[pdu], {num_left_to_take - 1, pdu}}
          end)

        timeline_events =
          if is_tuple(next_page_info) and stream_ends_at == :end_of_chunk and Enum.empty?(timeline_events) do
            # TODO: sync initiate backfill job
          else
            # TODO: async initiate backfill job
            bundle_aggregations(room, timeline_events, user_id)
          end

        get_known_memberships_fxn = fn -> LazyLoadMembersCache.get([room.id], device_id) end

        {:ok, Chunk.new(room, timeline_events, direction, from, next_page_info, get_known_memberships_fxn, filter)}
      end
    end)
  end

  defp get_membership(room_id, user_id) do
    case Room.get_membership(room_id, user_id) do
      :not_found -> {:error, :unauthorized}
      event -> {:ok, event}
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

  defp get_user_membership_at_pdu(%PDU{} = pdu, user_id) do
    {:ok, state_events} = Repo.get_all(PDU, pdu.state_events)

    case Enum.find(state_events, :none, &(&1.type == "m.room.member" and &1.state_key == user_id)) do
      :none -> "leave"
      %PDU{content: %{"membership" => membership}} -> membership
    end
  end

  def bundle_aggregations(_room, [], _user_id), do: []

  def bundle_aggregations(%Room{} = room, %PDU{} = pdu, user_id) do
    {:ok, child_pdus} = EventGraph.get_children(pdu, _recurse = 1)

    {:ok, user_latest_known_join_pdu} = Room.get_latest_known_join(room, user_id)

    case reject_unauthorized_child_pdus(child_pdus, user_id, user_latest_known_join_pdu) do
      [] -> pdu
      children -> PDU.Relationships.get_aggregations(pdu, user_id, children)
    end
  end

  def bundle_aggregations(room, events, user_id) do
    {:ok, child_pdus} = EventGraph.get_children(events, _recurse = 1)
    {:ok, user_latest_known_join_pdu} = Room.get_latest_known_join(room, user_id)

    authz_child_pdus = reject_unauthorized_child_pdus(child_pdus, user_id, user_latest_known_join_pdu)
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
  def reject_unauthorized_child_pdus(child_pdus, user_id, user_latest_known_join_pdu) do
    Enum.filter(child_pdus, &pdu_visible_to_user?(&1, user_id, user_latest_known_join_pdu))
  end

  @doc """
  Returns `true` if the given a `t:RadioBeam.PDU` is visible to `user_id`, else
  returns `false`.
  """
  def pdu_visible_to_user?(%PDU{} = pdu, user_id) do
    case Room.get_latest_known_join(pdu.room_id, user_id) do
      {:ok, user_latest_known_join} -> pdu_visible_to_user?(pdu, user_id, user_latest_known_join)
      {:error, :never_joined} -> pdu.current_visibility == "world_readable"
    end
  end

  defp pdu_visible_to_user?(%PDU{} = pdu, user_id, %PDU{} = user_latest_known_join_pdu) do
    {:ok, state_pdus} = Repo.get_all(PDU, pdu.state_events)

    maybe_membership_pdu = Enum.find(state_pdus, &(&1.type == "m.room.member" and &1.state_key == user_id))
    user_membership_at_pdu = get_in(maybe_membership_pdu.content["membership"]) || "leave"
    user_joined_later? = Core.user_joined_later?(pdu, user_latest_known_join_pdu)

    Core.user_authorized_to_view?(pdu, user_id, user_membership_at_pdu, user_joined_later?)
  end
end
