defmodule RadioBeam.Room.View.Core.Participating do
  @moduledoc """
  Tracks a user's membership across rooms using m.room.member events.
  """
  defstruct latest_known_join_pdus: %{}, all: MapSet.new(), invited: MapSet.new()

  @type t() :: %__MODULE__{}

  alias RadioBeam.Room.PDU

  def new!(), do: %__MODULE__{}

  def key_for(_room, %PDU{event: %{type: "m.room.member"} = event}), do: {:ok, {__MODULE__, event.state_key}}
  def key_for(_room, _pdu), do: :none

  def handle_pdu(%__MODULE__{} = participating, %{id: room_id}, %PDU{event: %{type: "m.room.member"}} = pdu) do
    latest_known_join_pdus =
      if pdu.event.content["membership"] == "join",
        do: Map.put(participating.latest_known_join_pdus, room_id, pdu),
        else: participating.latest_known_join_pdus

    invited_room_ids =
      if pdu.event.content["membership"] == "invite",
        do: MapSet.put(participating.invited, room_id),
        else: MapSet.delete(participating.invited, room_id)

    struct!(participating,
      latest_known_join_pdus: latest_known_join_pdus,
      all: MapSet.put(participating.all, room_id),
      invited: invited_room_ids
    )
  end
end
