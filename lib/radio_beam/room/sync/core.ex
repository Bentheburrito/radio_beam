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
  alias RadioBeam.User.EventFilter

  def perform(%Sync{} = sync, %Room{} = room) do
    {:ok, user_membership_pdu} = Room.State.fetch(room.state, "m.room.member", sync.user.id)
    user_membership = user_membership_pdu.event.content["membership"]

    ignored_user_ids =
      MapSet.new(sync.user.account_data[:global]["m.ignored_user_list"]["ignored_users"] || %{}, &elem(&1, 0))

    maybe_last_sync_room_state_pdus =
      with %PaginationToken{} = since <- sync.start,
           {:ok, %TopologicalID{} = order_id} <- PaginationToken.room_last_seen_order_id(since, room.id),
           {:ok, event_id} <- sync.functions.order_id_to_event_id.(room.id, order_id),
           {:ok, %PDU{} = pdu} <- Room.DAG.fetch(room.dag, event_id),
           {:ok, state_at_last_sync} <- Room.State.get_all_at(room.state, pdu) do
        state_at_last_sync
      else
        _ -> :initial
      end

    case user_membership do
      "leave" when not sync.filter.include_leave? ->
        :no_update

      membership when membership in ~w|ban join leave| ->
        with {:ok, event_stream} <- sync.functions.event_stream.(room.id) do
          joined_room_result(sync, room, membership, event_stream, ignored_user_ids, maybe_last_sync_room_state_pdus)
        end

      # TODO: should the invite reflect changes to stripped state events that
      # happened after the invite?
      "invite" when maybe_last_sync_room_state_pdus == :initial ->
        if user_membership_pdu.event.sender in ignored_user_ids do
          :no_update
        else
          InvitedRoomResult.new(room, sync.user.id)
        end

      "invite" ->
        :no_update

      "knock" ->
        # TOIMPL
        :no_update
    end
  end

  defp joined_room_result(sync, room, membership, event_stream, ignored_user_ids, maybe_last_sync_room_state_pdus) do
    to =
      with %PaginationToken{} = since <- sync.start,
           {:ok, %TopologicalID{} = to} <- PaginationToken.room_last_seen_order_id(since, room.id) do
        to
      else
        _ -> :none
      end

    not_passed_to = if to == :none, do: fn _ -> true end, else: &(TopologicalID.compare(&1, to) != :lt)

    [%Event{} = first_event] = Enum.take(event_stream, 1)

    {timeline_events, last_event} =
      event_stream
      |> Stream.reject(&Timeline.from_ignored_user?(&1, ignored_user_ids))
      |> Stream.filter(&EventFilter.allow_timeline_event?(sync.filter, &1))
      |> Stream.take(sync.filter.timeline.limit)
      |> Stream.take_while(not_passed_to)
      |> Enum.flat_map_reduce(first_event, &{[&1], &1})

    maybe_next_order_id =
      if last_event.order_id == to or last_event.type == "m.room.create" do
        :no_more_events
      else
        last_event.order_id
      end

    opts = [
      next_order_id: maybe_next_order_id,
      maybe_last_sync_room_state_pdus: maybe_last_sync_room_state_pdus,
      full_state?: sync.full_state?,
      known_memberships: sync.known_memberships,
      filter: sync.filter
    ]

    JoinedRoomResult.new(room, sync.user, timeline_events, sync.functions.get_events_for_user, membership, opts)
  end
end
