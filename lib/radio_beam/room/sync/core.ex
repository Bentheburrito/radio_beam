defmodule RadioBeam.Room.Sync.Core do
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.EventGraph.PaginationToken
  alias RadioBeam.Room.Sync
  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.Room.Timeline

  def perform(%Sync{} = sync, %Room{} = room) do
    {:ok, user_membership_pdu} = Room.State.fetch(room.state, "m.room.member", sync.user.id)
    user_membership = user_membership_pdu.event.content["membership"]

    ignored_user_ids =
      MapSet.new(sync.user.account_data[:global]["m.ignored_user_list"]["ignored_users"] || %{}, &elem(&1, 0))

    maybe_room_state_event_ids_at_last_sync =
      case Map.fetch!(sync.last_sync_pdus_by_room_id, room.id) do
        :initial -> :initial
        %PDU{state_events: state_events, state_key: nil} -> state_events
        %PDU{state_events: state_events, event_id: event_id} -> [event_id | state_events]
      end

    case user_membership do
      "leave" when not sync.filter.include_leave? ->
        :no_update

      membership when membership in ~w|ban join leave| ->
        last_sync_latest_event_id =
          case sync.last_sync_pdus_by_room_id[room.id] do
            %PDU{event_id: event_id} -> event_id
            :initial -> :initial
          end

        {timeline_events, {limited?, maybe_prev_batch}} =
          sync.functions.event_stream.(room.id)
          |> Timeline.Core.from_event_stream(
            :backward,
            sync.user.id,
            membership,
            latest_known_join_pdu,
            sync.filter,
            ignored_user_ids
          )
          # TODO: extract into Core.take_until_limit_or_last_sync
          |> Enum.flat_map_reduce({sync.filter.timeline.limit, nil}, fn
            %PDU{event_id: ^last_sync_latest_event_id}, {_num_left, _last_pdu} ->
              {:halt, {false, :no_earlier_events}}

            %PDU{type: "m.room.create"}, {0, _last_pdu} ->
              {:halt, {false, :no_earlier_events}}

            %PDU{type: "m.room.create"} = pdu, {_num_left, _last_pdu} ->
              {[pdu], {false, :no_earlier_events}}

            _pdu, {0, last_pdu} ->
              {:halt, {true, PaginationToken.new(last_pdu, :backward)}}

            pdu, {num_left_to_take, _last_pdu} ->
              {[pdu], {num_left_to_take - 1, pdu}}
          end)

        # TODO / FIX: only need this for syncs that had nothing new initially, and
        # move to wait for new events till a timeout. Refactor later
        {limited?, maybe_prev_batch} =
          with {num_left_to_take, %PDU{}} when is_integer(num_left_to_take) <- {limited?, maybe_prev_batch} do
            {false, :no_earlier_events}
          end

        JoinedRoomResult.new(
          room,
          sync.user,
          timeline_events,
          limited?,
          maybe_prev_batch,
          maybe_room_state_event_ids_at_last_sync,
          sync.functions.get_events_for_user,
          sync.full_state?,
          membership,
          sync.known_memberships,
          sync.filter
        )

      # TODO: should the invite reflect changes to stripped state events that
      # happened after the invite?
      "invite" when maybe_room_state_event_ids_at_last_sync == :initial ->
        if user_membership_pdu.sender in ignored_user_ids do
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
end
