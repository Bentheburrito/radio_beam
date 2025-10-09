defmodule RadioBeam.Room.Sync.JoinedRoomResult do
  @moduledoc false

  alias RadioBeam.User
  alias RadioBeam.User.EventFilter
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.Room.View.Core.Timeline.Event

  defstruct ~w|room_id room_version timeline_events limited? maybe_prev_batch latest_seen_event state_events sender_ids filter current_membership account_data|a

  @type t() :: %__MODULE__{room_id: Room.id(), timeline_events: [PDU.t()], state_events: [PDU.event_id()]}
  @type maybe_prev_batch() :: :no_earlier_events | TopologicalID.t()

  # TODO: reduce args by taking `opts`
  @spec new(
          Room.t(),
          User.t(),
          [PDU.t()],
          boolean(),
          maybe_prev_batch(),
          [PDU.t()] | :initial,
          ([PDU.event_id()] -> [PDU.t()]),
          boolean(),
          String.t(),
          %{Room.id() => User.id()},
          EventFilter.t()
        ) ::
          t() | :no_update
  def new(
        room,
        user,
        timeline_events,
        limited?,
        maybe_prev_batch,
        maybe_room_state_event_ids_at_last_sync,
        get_events_for_user,
        full_state?,
        membership,
        known_memberships,
        filter
      ) do
    sender_ids = if filter.state.memberships == :all, do: MapSet.new(), else: MapSet.new(timeline_events, & &1.sender)
    sender_ids = MapSet.put(sender_ids, user.id)

    state_events =
      if EventFilter.allow_state_in_room?(filter, room.id) do
        determine_state_events(
          room,
          timeline_events,
          maybe_room_state_event_ids_at_last_sync,
          get_events_for_user,
          full_state?,
          known_memberships,
          sender_ids,
          filter
        )
      else
        []
      end

    if Enum.empty?(timeline_events) and Enum.empty?(state_events) do
      :no_update
    else
      latest_seen_event = hd(timeline_events)

      timeline_events =
        if EventFilter.allow_timeline_in_room?(filter, room.id) do
          timeline_events
          |> bundle_aggregations(user.id)
          |> Enum.sort_by(& &1.order_id)
        else
          []
        end

      %__MODULE__{
        room_id: room.id,
        room_version: room.version,
        timeline_events: timeline_events,
        limited?: limited?,
        maybe_prev_batch: maybe_prev_batch,
        latest_seen_event: latest_seen_event,
        state_events: state_events,
        sender_ids: sender_ids,
        filter: filter,
        current_membership: membership,
        account_data: Map.get(user.account_data, room.id, %{})
      }
    end
  end

  defp determine_state_events(
         room,
         timeline_events,
         maybe_room_state_event_ids_at_last_sync,
         get_events_for_user,
         full_state?,
         known_memberships,
         sender_ids,
         filter
       ) do
    {room_state_event_ids_at_last_sync, desired_state_events} =
      if maybe_room_state_event_ids_at_last_sync == :initial or full_state?,
        do: {[], :at_timeline_start},
        else: {maybe_room_state_event_ids_at_last_sync, :delta}

    # we will never be in a situation where maybe_room_state_event_ids_at_last_sync = :initial
    # AND List.last(timeline_events) = nil, because an init sync will always return some
    # events, and an incremental sync will always have a "last known state" of the last sync
    state_event_ids_at_tl_start =
      case List.last(timeline_events) do
        %Event{} = oldest_tl_event ->
          %PDU{} = oldest_tl_pdu = Room.DAG.fetch!(room.dag, oldest_tl_event.id)

          room.state
          |> Room.State.get_all_at(oldest_tl_pdu)
          |> Enum.map(fn {_k, pdu} -> pdu.event.id end)

        nil ->
          room_state_event_ids_at_last_sync
      end

    state_event_ids =
      determine_state_event_ids(room_state_event_ids_at_last_sync, state_event_ids_at_tl_start, desired_state_events)

    known_memberships = Map.get(known_memberships, room.id, MapSet.new())

    get_events_for_user.(room.id, state_event_ids_at_tl_start)
    |> Stream.filter(&(&1.id in state_event_ids))
    |> Stream.filter(&EventFilter.allow_state_event?(filter, &1, sender_ids, known_memberships))
  end

  defp determine_state_event_ids(_, state_event_ids_at_tl_start, :at_timeline_start), do: state_event_ids_at_tl_start

  defp determine_state_event_ids(last_sync_state_ids, state_event_ids_at_tl_start, :delta) do
    state_event_ids_at_tl_start
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(last_sync_state_ids))
  end

  defimpl Jason.Encoder do
    alias RadioBeam.Room.Sync.JoinedRoomResult

    def encode(%JoinedRoomResult{} = room_result, opts) do
      format = String.to_existing_atom(room_result.filter.format)

      to_event = fn pdu ->
        pdu
        |> RadioBeam.PDU.to_event(room_result.room_version, :strings, format)
        |> RadioBeam.User.EventFilter.take_fields(room_result.filter.fields)
      end

      timeline = %{events: Enum.map(room_result.timeline_events, to_event), limited: room_result.limited?}

      timeline =
        case room_result.maybe_prev_batch do
          :no_earlier_events -> timeline
          %TopologicalID{} = prev_batch -> Map.put(timeline, :prev_batch, prev_batch)
        end

      Jason.Encode.map(
        %{
          timeline: timeline,
          state: %{events: Enum.map(room_result.state_events, to_event)},
          account_data: room_result.account_data
        },
        opts
      )
    end
  end

  # since /sync returns the latest events of a timeline, and children define
  # relationships with their parents, we can be sure any aggregations we need
  # to bundle are already in the timeline.
  defp bundle_aggregations(pdus, user_id) do
    event_ids = MapSet.new(pdus, & &1.event_id)

    {child_pdus, pdus} = Enum.split_with(pdus, &(&1.parent_id in event_ids and PDU.Relationships.aggregable?(&1)))
    child_pdus_by_parent_id = Enum.group_by(child_pdus, & &1.parent_id)

    Enum.map(pdus, fn %PDU{} = pdu ->
      case Map.fetch(child_pdus_by_parent_id, pdu.event_id) do
        {:ok, child_pdus} -> PDU.Relationships.get_aggregations(pdu, user_id, child_pdus)
        :error -> pdu
      end
    end)
  end
end
