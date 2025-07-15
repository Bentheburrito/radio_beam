defmodule RadioBeam.Room.Sync.InvitedRoomResult do
  alias RadioBeam.Room

  defstruct ~w|room_id stripped_state_events|a

  @type t() :: %__MODULE__{room_id: Room.id(), stripped_state_events: [map()]}

  def new(room, user_id), do: %__MODULE__{room_id: room.id, stripped_state_events: Room.stripped_state(room, user_id)}

  defimpl Jason.Encoder do
    alias RadioBeam.Room.Sync.InvitedRoomResult

    @stripped_keys ~w|content sender state_key type|a
    def encode(%InvitedRoomResult{} = room_result, opts) do
      stripped_state_events = Enum.map(room_result.stripped_state_events, &Map.take(&1, @stripped_keys))
      Jason.Encode.map(%{"invite_state" => %{"events" => stripped_state_events}}, opts)
    end
  end
end
