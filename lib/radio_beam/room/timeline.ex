defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  require Logger

  alias RadioBeam.Room
  alias RadioBeam.Room.Database
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room.View.Core.Participating
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.User
  alias RadioBeam.User.EventFilter

  @doc """
  Get a chunk of `room_id` events visible to the given `user_id`, starting at
  the event whose ID `from`, up to the limit or a provided `to` event ID. The
  user must have a membership event in the room.

  ### Options

  - `to`: An event ID token to return events up to.
  - `filter`: A `User.EventFilter` to apply to returned events.
  - `limit`: If `filter` is not supplied, this will apply a maximum limit of
    events returned. Otherwise the `EventFilter`'s limits will be applied.
  """
  # credo:disable-for-lines:62 Credo.Check.Refactor.CyclomaticComplexity
  def get_messages(room_id, user_id, device_id, from, opts \\ []) do
    with :ok <- check_membership(room_id, user_id),
         {:ok, %Room{} = room} <- Database.fetch_room(room_id),
         {:ok, user_event_stream} <- Room.View.timeline_event_stream(room.id, user_id, from) do
      direction = dir_of_from(from)
      %{filter: filter, ignored_user_ids: ignored_user_ids} = get_user_timeline_preferences(user_id, opts)

      maybe_to_event =
        with "$" <> _ = to_event_id <- Keyword.get(opts, :to, :none),
             {:ok, to_event_stream} <- Room.View.get_events(room.id, user_id, [to_event_id]),
             [to_event] <- Enum.take(to_event_stream, 1) do
          to_event
        else
          _ -> :none
        end

      not_passed_to =
        cond do
          maybe_to_event == :none -> fn _ -> true end
          direction == :forward -> &(TopologicalID.compare(&1.order_id, maybe_to_event.order_id) != :gt)
          direction == :backward -> &(TopologicalID.compare(&1.order_id, maybe_to_event.order_id) != :lt)
        end

      num_to_drop = if from in ~w|tip root|a, do: 0, else: 1

      {timeline_events, maybe_next_event_id} =
        user_event_stream
        |> Stream.drop(num_to_drop)
        |> Stream.filter(&allow_event_for_user?(&1, filter, ignored_user_ids, maybe_to_event))
        |> Stream.take(filter.timeline.limit)
        |> Stream.take_while(not_passed_to)
        |> Enum.flat_map_reduce(:no_more_events, fn event, _last_event_id ->
          cond do
            maybe_to_event != :none and event.id == maybe_to_event.id -> {[], :no_more_events}
            event.type == "m.room.create" and direction == :backward -> {[event], :no_more_events}
            :else -> {[event], event.id}
          end
        end)

      # TODO: need to detect when we have reached the end of a chunk, and
      #       initiate a backfill over federation

      get_known_memberships_fxn = fn -> LazyLoadMembersCache.get([room.id], device_id) end

      relevant_state_event_stream = get_state_events(room, user_id, timeline_events, get_known_memberships_fxn, filter)

      {:ok, timeline_events, maybe_next_event_id, relevant_state_event_stream}
    end
  end

  def allow_event_for_user?(event, filter, ignored_user_ids, %{id: to_event_id}),
    do: allow_event_for_user?(event, filter, ignored_user_ids, to_event_id)

  def allow_event_for_user?(event, filter, ignored_user_ids, maybe_to_event_id) do
    event.id == maybe_to_event_id or
      (not from_ignored_user?(event, ignored_user_ids) and EventFilter.allow_timeline_event?(filter, event))
  end

  defp from_ignored_user?(event, ignored_user_ids), do: is_nil(event.state_key) and event.sender in ignored_user_ids

  defp check_membership(room_id, user_id) do
    with {:ok, %Participating{all: room_ids_with_membership}} <- Room.View.all_participating(user_id) do
      if room_id in room_ids_with_membership, do: :ok, else: {:error, :unauthorized}
    end
  end

  defp dir_of_from(:root), do: :forward
  defp dir_of_from(:tip), do: :backward
  defp dir_of_from({_event_id, direction}), do: direction

  defp get_user_timeline_preferences(user_id, opts) do
    maybe_filter_or_filter_id = Keyword.get(opts, :filter, :none)

    User.get_timeline_preferences(user_id, maybe_filter_or_filter_id)
  end

  defp get_state_events(room, user_id, timeline_events, get_known_memberships_fxn, filter) do
    ignore_memberships_from =
      if filter.state.memberships == :lazy do
        known_membership_map = get_known_memberships_fxn.()
        Map.get(known_membership_map, room.id, [])
      else
        []
      end

    state_event_ids =
      timeline_events
      |> Stream.reject(&(&1.sender in ignore_memberships_from))
      |> Stream.uniq_by(& &1.sender)
      |> Enum.map(fn pdu ->
        # TODO: use Room.get_members instead of accessing state directly...
        {:ok, event_id} = Room.Core.get_state_mapping(room, "m.room.member", pdu.sender)
        event_id
      end)

    Room.View.get_events!(room.id, user_id, state_event_ids)
  end

  def get_context(room_id, user_id, device_id, event_id, opts) do
    with {:ok, event_stream} <- Room.View.get_events(room_id, user_id, [event_id], true),
         {:ok, prev_events, prev_end, _} <- get_messages(room_id, user_id, device_id, {event_id, :backward}, opts),
         {:ok, next_events, next_end, _} <- get_messages(room_id, user_id, device_id, {event_id, :forward}, opts) do
      [event] = Enum.take(event_stream, 1)
      {:ok, event, prev_events, prev_end, next_events, next_end}
    end
  end
end
