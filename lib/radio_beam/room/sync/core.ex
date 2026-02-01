defmodule RadioBeam.Room.Sync.Core do
  @moduledoc false
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.Room.Timeline
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID

  def perform(%{} = inputs, %Room{} = room) do
    {:ok, user_membership_pdu} = Room.State.fetch(room.state, "m.room.member", inputs.user_id)
    user_membership = user_membership_pdu.event.content["membership"]

    maybe_last_sync_room_state_pdus =
      with "$" <> _ = event_id <- inputs.last_batch,
           {:ok, %PDU{} = pdu} <- Room.DAG.fetch(room.dag, event_id),
           %{} = state_at_last_sync <- Room.State.get_all_at(room.state, pdu) do
        Map.values(state_at_last_sync)
      else
        _ -> :initial
      end

    case user_membership do
      "leave" when not inputs.event_filter.include_leave? ->
        :no_update

      membership when membership in ~w|ban join leave| ->
        event_stream = inputs.functions.event_stream.(room.id)
        typing_user_ids = inputs.functions.typing_user_ids.(room.id)

        if Enum.empty?(event_stream) do
          :no_update
        else
          joined_room_result(
            inputs,
            room,
            membership,
            event_stream,
            maybe_last_sync_room_state_pdus,
            typing_user_ids
          )
        end

      "invite" when maybe_last_sync_room_state_pdus == :initial ->
        if user_membership_pdu.event.sender in inputs.ignored_user_ids do
          :no_update
        else
          InvitedRoomResult.new!(room, inputs.user_id)
        end

      "invite" ->
        :no_update

      "knock" ->
        # TOIMPL
        :no_update
    end
  end

  defp joined_room_result(
         inputs,
         room,
         membership,
         event_stream,
         maybe_last_sync_room_state_pdus,
         typing_user_ids
       ) do
    maybe_to_event =
      with "$" <> _ = to_event_id <- inputs.last_batch,
           to_event_stream <- inputs.functions.get_events_for_user.(room.id, [to_event_id]),
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
      |> Stream.filter(
        &Timeline.allow_event_for_user?(&1, inputs.event_filter, inputs.ignored_user_ids, maybe_to_event)
      )
      |> Stream.take(inputs.event_filter.timeline.limit)
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
      full_state?: inputs.full_state?,
      known_memberships: inputs.known_memberships,
      filter: inputs.event_filter,
      typing: typing_user_ids
    ]

    JoinedRoomResult.new(
      room,
      inputs.user_id,
      inputs.account_data,
      timeline_events,
      inputs.functions.get_events_for_user,
      membership,
      opts
    )
  end
end
