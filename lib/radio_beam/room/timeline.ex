defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  require Logger

  alias RadioBeam.Room
  alias RadioBeam.Room.Database
  alias RadioBeam.Room.Timeline.Chunk
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room.View.Core.Participating
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.Sync.NextBatch
  alias RadioBeam.User
  alias RadioBeam.User.EventFilter

  @doc """
  Get a chunk of `room_id` events visible to the given `user_id`, starting at
  `from`, up to the limit or a provided `to`. The user must have a membership
  event in the room.

  ### Options

  - `to`: A `NextBatch` token to return events up to.
  - `filter`: A `User.EventFilter` to apply to returned events.
  - `limit`: If `filter` is not supplied, this will apply a maximum limit of
    events returned. Otherwise the `EventFilter`'s limits will be applied.
  """
  # credo:disable-for-lines:93 Credo.Check.Refactor.CyclomaticComplexity
  def get_messages(room_id, user_id, device_id, from_token, opts \\ []) do
    with :ok <- check_membership(room_id, user_id),
         {:ok, %Room{} = room} <- Database.fetch_room(room_id),
         {:ok, from, direction} <- map_from_pagination_token(from_token, room_id),
         {:ok, user_event_stream} <- Room.View.timeline_event_stream(room.id, user_id, from) do
      %{filter: filter, ignored_user_ids: ignored_user_ids} = get_user_timeline_preferences(user_id, opts)

      maybe_to_event =
        with %NextBatch{} = since <- Keyword.get(opts, :to, :none),
             {:ok, to_event_id} <- NextBatch.fetch(since, room.id),
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

      event_stream =
        case from_token do
          {%NextBatch{} = from, _dir} ->
            if NextBatch.direction(from) != direction do
              user_event_stream
            else
              Stream.drop(user_event_stream, 1)
            end

          _else ->
            user_event_stream
        end

      {timeline_events, maybe_next_event_id} =
        event_stream
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
      get_events_for_user = &Room.View.get_events!(room_id, user_id, &1)

      start_direction =
        case from_token do
          {%NextBatch{} = from, _dir} -> NextBatch.direction(from)
          _else -> if direction == :forward, do: :backward, else: :forward
        end

      start_token =
        case Enum.take(user_event_stream, 1) do
          [first_event | _] ->
            NextBatch.new!(System.os_time(:millisecond), %{room_id => first_event.id}, start_direction)

          [] ->
            NextBatch.new!(System.os_time(:millisecond), %{}, start_direction)
        end

      end_token =
        if maybe_next_event_id == :no_more_events,
          do: :no_more_events,
          else: NextBatch.new!(System.os_time(:millisecond), %{room_id => maybe_next_event_id}, direction)

      {:ok,
       Chunk.new(room, timeline_events, start_token, end_token, get_known_memberships_fxn, get_events_for_user, filter)}
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

  defp map_from_pagination_token(:root, _room_id), do: {:ok, :root, :forward}
  defp map_from_pagination_token(:tip, _room_id), do: {:ok, :tip, :backward}

  defp map_from_pagination_token({%NextBatch{} = token, direction}, room_id) do
    case NextBatch.fetch(token, room_id) do
      {:ok, event_id} -> {:ok, {event_id, direction}, direction}
      {:error, :not_found} -> {:error, :from_token_missing_room_id}
    end
  end

  defp get_user_timeline_preferences(user_id, opts) do
    maybe_filter_or_filter_id = Keyword.get(opts, :filter, :none)

    User.get_timeline_preferences(user_id, maybe_filter_or_filter_id)
  end

  def get_context(room_id, user_id, device_id, event_id, get_message_opts) do
    prev_token = :millisecond |> System.os_time() |> NextBatch.new!(%{room_id => event_id}, :backward)
    next_token = :millisecond |> System.os_time() |> NextBatch.new!(%{room_id => event_id}, :forward)

    with {:ok, event_stream} <- Room.View.get_events(room_id, user_id, [event_id], true),
         {:ok, prev_chunk} <- get_messages(room_id, user_id, device_id, {prev_token, :backward}, get_message_opts),
         {:ok, next_chunk} <- get_messages(room_id, user_id, device_id, {next_token, :forward}, get_message_opts) do
      [event] = Enum.take(event_stream, 1)
      {:ok, event, prev_chunk.timeline_events, prev_chunk.end, next_chunk.timeline_events, next_chunk.end}
    end
  end
end
