defmodule RadioBeam.Room.Sync.InvitedRoomResult do
  alias RadioBeam.Room
  alias RadioBeam.Room.View.Core.Timeline.Event

  defstruct ~w|room_id stripped_state_events user_invite_event_id|a

  @type t() :: %__MODULE__{room_id: Room.id(), stripped_state_events: [map()], user_invite_event_id: Room.event_id()}

  def new!(room, user_id, user_invite_event_id) do
    stripped_state_events =
      room.state
      |> Room.State.get_invite_state_pdus(user_id)
      |> Stream.map(&Event.new!(:unknown, &1, []))

    %__MODULE__{
      room_id: room.id,
      stripped_state_events: stripped_state_events,
      user_invite_event_id: user_invite_event_id
    }
  end

  defimpl JSON.Encoder do
    alias RadioBeam.Room.Sync.InvitedRoomResult

    @stripped_keys ~w|content sender state_key type|a
    def encode(%InvitedRoomResult{} = room_result, encoder) do
      stripped_state_events = Enum.map(room_result.stripped_state_events, &Map.take(&1, @stripped_keys))
      JSON.Encoder.Map.encode(%{"invite_state" => %{"events" => stripped_state_events}}, encoder)
    end
  end
end
