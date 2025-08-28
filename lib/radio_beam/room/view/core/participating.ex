defmodule RadioBeam.Room.View.Core.Participating do
  @moduledoc """
  Tracks a user's membership across rooms using m.room.member events.
  """
  defstruct joined: MapSet.new(), all: MapSet.new()

  alias RadioBeam.Room.PDU

  def new!(), do: %__MODULE__{}

  def key_for(_room, %PDU{event: %{type: "m.room.member"} = event}), do: {:ok, {__MODULE__, event.state_key}}
  def key_for(_room, _pdu), do: :none

  def handle_pdu(%__MODULE__{} = participating, %{id: room_id}, %PDU{event: %{type: "m.room.member"} = event}) do
    joined =
      if event.content["membership"] == "join",
        do: MapSet.put(participating.joined, room_id),
        else: participating.joined

    struct!(participating,
      joined: joined,
      all: MapSet.put(participating.all, room_id)
    )
  end
end
