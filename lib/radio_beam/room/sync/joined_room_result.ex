defmodule RadioBeam.Room.Sync.JoinedRoomResult do
  @moduledoc false

  alias RadioBeam.User.EventFilter
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID

  defstruct ~w|room_id timeline_events maybe_next_event_id latest_event_id state_events sender_ids filter current_membership account_data typing|a

  @type t() :: %__MODULE__{room_id: Room.id(), timeline_events: [Event.t()], state_events: [Room.event_id()]}

  @type get_events_for_user() :: (Room.id(), [Room.event_id()] -> [Event.t()])
  @type user_membership() :: String.t()

  @type opt() ::
          {:next_event_id, Room.event_id() | :no_more_events}
          | {:maybe_last_sync_room_state_pdus, [PDU.t()] | :initial}
          | {:full_state?, boolean()}
          | {:known_memberships, %{Room.id() => MapSet.t(User.id())}}
          | {:filter, EventFilter.t()}
  @type opts() :: [opt()]

  @spec new(Room.t(), User.t(), Enumerable.t(Event.t()), get_events_for_user(), user_membership(), opts()) ::
          t() | :no_update
  def new(room, user, timeline_events, get_events_for_user, membership, opts \\ []) do
    filter = Keyword.get_lazy(opts, :filter, fn -> EventFilter.new(%{}) end)
    maybe_last_sync_room_state_pdus = Keyword.get(opts, :maybe_last_sync_room_state_pdus, :initial)
    full_state? = Keyword.get(opts, :full_state?, false)
    known_memberships = Keyword.get(opts, :known_memberships, %{})

    sender_ids =
      if filter.state.memberships == :all, do: MapSet.new(), else: MapSet.new(timeline_events, & &1.sender)

    sender_ids = MapSet.put(sender_ids, user.id)

    state_events =
      if EventFilter.allow_state_in_room?(filter, room.id) do
        determine_state_events(
          room,
          timeline_events,
          maybe_last_sync_room_state_pdus,
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
      latest_event_id = hd(timeline_events).id

      timeline_events =
        if EventFilter.allow_timeline_in_room?(filter, room.id) do
          timeline_events
          |> Enum.sort_by(& &1.order_id, {:asc, TopologicalID})
          |> remove_bundled_from_timeline()
          |> Enum.to_list()
        else
          []
        end

      %__MODULE__{
        room_id: room.id,
        timeline_events: timeline_events,
        maybe_next_event_id: Keyword.get(opts, :next_event_id, :no_more_events),
        latest_event_id: latest_event_id,
        state_events: state_events,
        sender_ids: sender_ids,
        filter: filter,
        current_membership: membership,
        account_data: Map.get(user.account_data, room.id, %{}),
        typing: Keyword.get(opts, :typing, [])
      }
    end
  end

  def new_ephemeral(room_id, user, membership, typing_user_ids) do
    %__MODULE__{
      room_id: room_id,
      timeline_events: [],
      maybe_next_event_id: :no_more_events,
      latest_event_id: :use_latest,
      state_events: [],
      sender_ids: MapSet.new(),
      filter: EventFilter.new(%{}),
      current_membership: membership,
      account_data: Map.get(user.account_data, room_id, %{}),
      typing: typing_user_ids
    }
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
        do: {[], :before_timeline_start},
        else: {maybe_last_sync_room_state_pdus, :delta}

    # we will never be in a situation where maybe_last_sync_room_state_pdus =
    # :initial AND List.last(timeline_events) = nil, because an init sync will
    # always return some events, and an incremental sync will always have a
    # "last known state" of the last sync
    state_event_ids_at_tl_start =
      case List.last(timeline_events) do
        %Event{} = oldest_tl_event ->
          %PDU{} = oldest_tl_pdu = Room.DAG.fetch!(room.dag, oldest_tl_event.id)

          oldest_tl_event_id = oldest_tl_event.id

          room.state
          |> Room.State.get_all_at(oldest_tl_pdu)
          # |> Stream.reject(fn {_k, pdu} -> pdu.event.id == oldest_tl_event.id end)
          |> Enum.flat_map(fn
            # If the oldest TL event is a state event, we want to get the
            # previous value/state event it changed from. I.e. the state
            # *before* the first event in the TL. Yes, I know it's fugly.
            {_k, %{event: %{id: ^oldest_tl_event_id}, prev_event_ids: [prev_event_id]} = pdu} ->
              prev_pdu = Room.DAG.fetch!(room.dag, prev_event_id)

              case Room.State.fetch_at(room.state, pdu.event.type, pdu.event.state_key, prev_pdu) do
                {:ok, prev_state_pdu} -> [prev_state_pdu.event.id]
                {:error, :not_found} -> []
              end

            {_k, %{event: %{id: ^oldest_tl_event_id}, prev_event_ids: []}} ->
              []

            {_k, pdu} ->
              [pdu.event.id]
          end)

        nil ->
          Enum.map(room_state_pdus_at_last_sync, & &1.event.id)
      end

    state_event_ids =
      room_state_pdus_at_last_sync
      |> Stream.map(& &1.event.id)
      |> determine_state_event_ids(state_event_ids_at_tl_start, desired_state_events)

    known_memberships = Map.get(known_memberships, room.id, MapSet.new())

    get_events_for_user.(room.id, state_event_ids_at_tl_start)
    |> Stream.filter(&(&1.id in state_event_ids))
    |> Stream.filter(&EventFilter.allow_state_event?(filter, &1, sender_ids, known_memberships))
  end

  defp determine_state_event_ids(_, state_event_ids_at_tl_start, :before_timeline_start),
    do: state_event_ids_at_tl_start

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
        |> Event.to_map()
        |> EventFilter.take_fields(room_result.filter.fields)
      end

      limited? = room_result.maybe_next_event_id != :no_more_events

      timeline = %{events: Enum.map(room_result.timeline_events, to_event), limited: limited?}

      timeline =
        case room_result.maybe_next_event_id do
          :no_more_events -> timeline
          next_event_id -> Map.put(timeline, :prev_batch, next_event_id)
        end

      Jason.Encode.map(
        %{
          timeline: timeline,
          state: %{events: Enum.map(room_result.state_events, to_event)},
          ephemeral: %{events: encode_ephemeral(room_result.typing)},
          account_data: room_result.account_data
        },
        opts
      )
    end

    defp encode_ephemeral([]), do: []
    defp encode_ephemeral(user_ids), do: [encode_typing(user_ids)]

    defp encode_typing(user_ids) do
      %{
        type: "m.typing",
        content: %{user_ids: user_ids}
      }
    end
  end

  # we need to remove events that have been bundled with an older event
  # included in this sync response.
  # this fxn assumes the bundled event ID comes after the bundled-to event in
  # the timeline...which may not hold true in some federated cases, where we
  # receive the bundled event before the bundled-to event...
  defp remove_bundled_from_timeline(events) do
    Stream.transform(events, _seen_bundled_event_ids = MapSet.new(), fn
      event, seen_bundled_event_ids ->
        if event.id in seen_bundled_event_ids do
          {[], seen_bundled_event_ids}
        else
          {[event], MapSet.union(seen_bundled_event_ids, MapSet.new(event.bundled_events, & &1.id))}
        end
    end)
  end
end
