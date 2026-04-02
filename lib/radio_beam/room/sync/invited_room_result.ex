defmodule RadioBeam.Room.Sync.InvitedRoomResult do
  @moduledoc false

  defstruct ~w|room_id stripped_state_events|a

  @type t() :: %__MODULE__{stripped_state_events: [map()]}

  def new!(room_id, stripped_state_events) when is_list(stripped_state_events) do
    %__MODULE__{room_id: room_id, stripped_state_events: stripped_state_events}
  end

  defimpl JSON.Encoder do
    alias RadioBeam.Room.Sync.InvitedRoomResult

    def encode(%InvitedRoomResult{} = room_result, encoder) do
      JSON.Encoder.Map.encode(%{"invite_state" => %{"events" => room_result.stripped_state_events}}, encoder)
    end
  end
end
