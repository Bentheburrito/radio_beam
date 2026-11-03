defmodule RadioBeam.Room.Timeline do
  @moduledoc """
  Functions for reading the timeline of a room, primarily for the purposes of
  syncing with clients.
  """

  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
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

  ### A note on event ordering

  This function follows the precedent set by Conduit to use stream ordering,
  despite the spec declaring "topological" ordering. This will almost certainly
  not be the case forever, considering it leads to a pretty horrible UX in
  network partitions/late events (confusing timeline ordering). It will
  especially be desirable to change the ordering of events here if the spec
  ever actually defines what topological ordering *means*…see **Relevant
  Links** below for more information (notice how all of this information has to
  be scoured from the Internet, and is not documented in the spec at all - the
  best you get are some GH issues from 5-10+ *years* ago).

  #### Relevant Links

  - https://news.ycombinator.com/item?id=42324114
  - https://artificialworlds.net/blog/2024/12/04/message-order-in-matrix/
  - https://matrix-org.github.io/synapse/v1.98/development/room-dag-concepts.html
  - https://github.com/matrix-org/matrix-spec/issues/852
  - https://github.com/matrix-org/matrix-spec/issues/125
  """
  # credo:disable-for-lines:62 Credo.Check.Refactor.CyclomaticComplexity
  def get_messages(room_id, user_id, device_id, from, opts \\ []) do
    with :ok <- check_membership(room_id, user_id),
         {:ok, from} <- map_from_event_id_to_stream_number(from, room_id) do
      user_event_stream = Room.View.timeline_event_stream(room_id, user_id, from)
      direction = dir_of_from(from)
      %{filter: filter, ignored_user_ids: ignored_user_ids} = get_user_timeline_preferences(user_id, opts)

      {timeline_events, {count, last_event_id}} =
        user_event_stream
        |> Stream.filter(&allow_event_for_user?(&1, filter, ignored_user_ids))
        |> take_until_to_or_limit(room_id, user_id, Keyword.get(opts, :to, :none), filter.timeline.limit)
        |> Enum.flat_map_reduce({_count = 0, :no_more_events}, fn e, {count, _} -> {[e], {count + 1, e.id}} end)

      # we don't consider the latest events "the end" of the timeline - there
      # will be more events accessible eventually
      to_specified? = is_binary(Keyword.get(opts, :to, :none))

      next_page =
        if count < filter.timeline.limit and (direction == :backward or to_specified?),
          do: :no_more_events,
          else: last_event_id

      # TODO: need to detect when we have reached the end of a chunk, and
      #       initiate a backfill over federation

      relevant_memberships = relevant_membership_events(room_id, user_id, timeline_events, device_id, filter)

      {:ok, timeline_events, next_page, relevant_memberships}
    end
  end

  defp take_until_to_or_limit(event_stream, _room_id, _user_id, to, limit) when to in ~w|none limit|a,
    do: Stream.take(event_stream, limit)

  defp take_until_to_or_limit(event_stream, room_id, user_id, "$" <> _ = to_event_id, limit) do
    to_take =
      with {:ok, to_event} <- Room.View.Timeline.fetch_user_event(room_id, user_id, to_event_id),
           [%{order_id: order_id}] <- Enum.take(event_stream, 1) do
        min(limit, abs(order_id - to_event.order_id))
      else
        _invalid_to_event_id_or_empty_stream -> limit
      end

    Stream.take(event_stream, to_take)
  end

  defp map_from_event_id_to_stream_number({dir, event_id}, room_id) do
    case Room.fetch_pdu(room_id, event_id) do
      {:ok, %{stream_number: stream_number}} -> {:ok, {dir, stream_number}}
      _else -> {:error, :from_not_found}
    end
  end

  defp map_from_event_id_to_stream_number(from, _room_id) when from in ~w|root tip|a, do: {:ok, from}

  def allow_event_for_user?(event, filter, ignored_user_ids) do
    not from_ignored_user?(event, ignored_user_ids) and EventFilter.allow_timeline_event?(filter, event)
  end

  defp from_ignored_user?(event, ignored_user_ids), do: is_nil(event.state_key) and event.sender in ignored_user_ids

  defp check_membership(room_id, user_id) do
    if room_id in User.RoomMemberships.joined_now_or_previously(user_id), do: :ok, else: {:error, :unauthorized}
  end

  defp dir_of_from(:root), do: :forward
  defp dir_of_from(:tip), do: :backward
  defp dir_of_from({direction, _event_id}), do: direction

  defp get_user_timeline_preferences(user_id, opts) do
    maybe_filter_or_filter_id = Keyword.get(opts, :filter, :none)

    User.get_timeline_preferences(user_id, maybe_filter_or_filter_id)
  end

  defp relevant_membership_events(room_id, user_id, timeline_events, device_id, filter) do
    ignore_memberships_from =
      if filter.state.memberships == :lazy do
        known_membership_map = LazyLoadMembersCache.get([room_id], device_id)
        Map.get(known_membership_map, room_id, [])
      else
        []
      end

    with {:ok, memberships_events} <- Room.get_members(room_id, user_id, :latest_visible) do
      membership_events_by_state_key =
        Map.new(memberships_events, fn event -> {event.state_key, event} end)

      timeline_events
      |> Stream.reject(&(&1.sender in ignore_memberships_from))
      |> Stream.uniq_by(& &1.sender)
      |> Enum.map(fn event -> Map.fetch!(membership_events_by_state_key, event.sender) end)
    end
  end

  def get_context(room_id, user_id, device_id, event_id, opts) do
    with {:ok, event} <- Room.View.Timeline.fetch_user_event(room_id, user_id, event_id),
         {:ok, prev_events, prev_end, _} <- get_messages(room_id, user_id, device_id, {:backward, event_id}, opts),
         {:ok, next_events, next_end, _} <- get_messages(room_id, user_id, device_id, {:forward, event_id}, opts) do
      {:ok, event, prev_events, prev_end, next_events, next_end}
    end
  end
end
