defmodule RadioBeam.Room.Sync.Core do
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.Room.Sync
  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.Room.Timeline
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID

  def perform(%Sync{} = sync, %Room{} = room) do
    {:ok, user_membership_pdu} = Room.State.fetch(room.state, "m.room.member", sync.user.id)
    user_membership = user_membership_pdu.event.content["membership"]

    ignored_user_ids =
      MapSet.new(sync.user.account_data[:global]["m.ignored_user_list"]["ignored_users"] || %{}, &elem(&1, 0))

    maybe_last_sync_room_state_pdus =
      with %PaginationToken{} = since <- sync.start,
           {:ok, event_id} <- PaginationToken.room_last_seen_event_id(since, room.id),
           {:ok, %PDU{} = pdu} <- Room.DAG.fetch(room.dag, event_id),
           %{} = state_at_last_sync <- Room.State.get_all_at(room.state, pdu) do
        Map.values(state_at_last_sync)
      else
        _ -> :initial
      end

    case user_membership do
      "leave" when not sync.filter.include_leave? ->
        :no_update

      membership when membership in ~w|ban join leave| ->
        event_stream = sync.functions.event_stream.(room.id)
        typing_user_ids = sync.functions.typing_user_ids.(room.id)

        if not Enum.empty?(event_stream) do
          joined_room_result(
            sync,
            room,
            membership,
            event_stream,
            ignored_user_ids,
            maybe_last_sync_room_state_pdus,
            typing_user_ids
          )
        else
          :no_update
        end

      "invite" when maybe_last_sync_room_state_pdus == :initial ->
        if user_membership_pdu.event.sender in ignored_user_ids do
          :no_update
        else
          InvitedRoomResult.new!(room, sync.user.id, user_membership_pdu.event.id)
        end

      "invite" ->
        :no_update

      "knock" ->
        # TOIMPL
        :no_update
    end
  end

  defp joined_room_result(
         sync,
         room,
         membership,
         event_stream,
         ignored_user_ids,
         maybe_last_sync_room_state_pdus,
         typing_user_ids
       ) do
    maybe_to_event =
      with %PaginationToken{} = since <- sync.start,
           {:ok, to_event_id} <- PaginationToken.room_last_seen_event_id(since, room.id),
           to_event_stream <- sync.functions.get_events_for_user.(room.id, [to_event_id]),
           [to_event] <- Enum.take(to_event_stream, 1) do
        to_event
      else
        _ -> :none
      end

    not_passed_to =
      if maybe_to_event == :none,
        do: fn _ -> true end,
        else: &(TopologicalID.compare(&1.order_id, maybe_to_event.order_id) != :lt)

    [%Event{} = first_event] = Enum.take(event_stream, 1)

    {timeline_events, maybe_next_event_id} =
      event_stream
      |> Stream.filter(&Timeline.allow_event_for_user?(&1, sync.filter, ignored_user_ids, maybe_to_event))
      |> Stream.take(sync.filter.timeline.limit)
      |> Stream.take_while(not_passed_to)
      |> Enum.flat_map_reduce(first_event.id, fn event, _last_event_id ->
        cond do
          maybe_to_event != :none and event.id == maybe_to_event.id -> {[], :no_more_events}
          event.type == "m.room.create" -> {[event], :no_more_events}
          :else -> {[event], event.id}
        end
      end)

    opts = [
      next_event_id: maybe_next_event_id,
      maybe_last_sync_room_state_pdus: maybe_last_sync_room_state_pdus,
      full_state?: sync.full_state?,
      known_memberships: sync.known_memberships,
      filter: sync.filter,
      typing: typing_user_ids
    ]

    JoinedRoomResult.new(room, sync.user, timeline_events, sync.functions.get_events_for_user, membership, opts)
  end
end
