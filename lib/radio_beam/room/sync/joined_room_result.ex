defmodule RadioBeam.Room.Sync.JoinedRoomResult do
  @moduledoc false

  alias RadioBeam.User.EventFilter
  alias RadioBeam.Room
  alias RadioBeam.Room.EventRelationships
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.Room.View.Core.Timeline.Event

  defstruct ~w|room_id room_version timeline_events maybe_next_order_id latest_order_id state_events sender_ids filter current_membership account_data|a

  @type t() :: %__MODULE__{room_id: Room.id(), timeline_events: [Event.t()], state_events: [Room.event_id()]}
  @type maybe_next_order_id() :: :no_more_events | TopologicalID.t()
  @typep user_membership() :: String.t()

  @spec new(
          Room.Sync.t(),
          Room.t(),
          Enumerable.t(Event.t()),
          maybe_next_order_id(),
          [PDU.t()] | :initial,
          user_membership()
        ) ::
          t() | :no_update
  def new(sync, room, timeline_events, maybe_next_order_id, maybe_last_sync_room_state_pdus, membership) do
    sender_ids =
      if sync.filter.state.memberships == :all, do: MapSet.new(), else: MapSet.new(timeline_events, & &1.sender)

    sender_ids = MapSet.put(sender_ids, sync.user.id)

    state_events =
      if EventFilter.allow_state_in_room?(sync.filter, room.id) do
        determine_state_events(
          room,
          timeline_events,
          maybe_last_sync_room_state_pdus,
          sync.functions.get_events_for_user,
          sync.full_state?,
          sync.known_memberships,
          sender_ids,
          sync.filter
        )
      else
        []
      end

    if Enum.empty?(timeline_events) and Enum.empty?(state_events) do
      :no_update
    else
      latest_order_id = hd(timeline_events).order_id

      timeline_events =
        if EventFilter.allow_timeline_in_room?(sync.filter, room.id) do
          timeline_events
          |> bundle_aggregations(sync.user.id)
          |> Enum.sort_by(& &1.order_id)
        else
          []
        end

      %__MODULE__{
        room_id: room.id,
        room_version: room.version,
        timeline_events: timeline_events,
        maybe_next_order_id: maybe_next_order_id,
        latest_order_id: latest_order_id,
        state_events: state_events,
        sender_ids: sender_ids,
        filter: sync.filter,
        current_membership: membership,
        account_data: Map.get(sync.user.account_data, room.id, %{})
      }
    end
  end

  defp determine_state_events(
         room,
         timeline_events,
         maybe_last_sync_room_state_pdus,
         get_events_for_user,
         full_state?,
         known_memberships,
         sender_ids,
         filter
       ) do
    {room_state_pdus_at_last_sync, desired_state_events} =
      if maybe_last_sync_room_state_pdus == :initial or full_state?,
        do: {[], :at_timeline_start},
        else: {maybe_last_sync_room_state_pdus, :delta}

    # we will never be in a situation where maybe_last_sync_room_state_pdus =
    # :initial AND List.last(timeline_events) = nil, because an init sync will
    # always return some events, and an incremental sync will always have a
    # "last known state" of the last sync
    state_event_ids_at_tl_start =
      case List.last(timeline_events) do
        %Event{} = oldest_tl_event ->
          %PDU{} = oldest_tl_pdu = Room.DAG.fetch!(room.dag, oldest_tl_event.id)

          room.state
          |> Room.State.get_all_at(oldest_tl_pdu)
          |> Enum.map(fn {_k, pdu} -> pdu.event.id end)

        nil ->
          Enum.map(room_state_pdus_at_last_sync, & &1.event.id)
      end

    state_event_ids =
      determine_state_event_ids(room_state_pdus_at_last_sync, state_event_ids_at_tl_start, desired_state_events)

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
      # format = String.to_existing_atom(room_result.filter.format)

      to_event = fn event ->
        event
        |> Event.to_map(room_result.room_version)
        |> EventFilter.take_fields(room_result.filter.fields)
      end

      limited? = room_result.maybe_next_order_id != :no_more_events

      timeline = %{events: Enum.map(room_result.timeline_events, to_event), limited: limited?}

      timeline =
        case room_result.maybe_next_order_id do
          :no_earlier_events -> timeline
          %TopologicalID{} = next_order_id -> Map.put(timeline, :prev_batch, next_order_id)
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
  defp bundle_aggregations(events, user_id) do
    event_ids = MapSet.new(events, & &1.id)

    {child_events, events} =
      Enum.split_with(events, &(parent_id(&1) in event_ids and EventRelationships.aggregable?(&1)))

    child_events_by_parent_id =
      Enum.group_by(child_events, &(parent_id(&1) in event_ids and EventRelationships.aggregable?(&1)))

    Enum.map(events, fn %Event{} = event ->
      case Map.fetch(child_events_by_parent_id, event.id) do
        {:ok, child_events} -> EventRelationships.get_aggregations(event, user_id, child_events)
        :error -> event
      end
    end)
  end

  defp parent_id(%Event{content: %{"m.relates_to" => %{"event_id" => parent_id}}}), do: parent_id
  defp parent_id(_event_with_no_parent), do: nil
end
