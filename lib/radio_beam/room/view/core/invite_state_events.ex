defmodule RadioBeam.Room.View.Core.InviteStateEvents do
  @moduledoc """
  Holds the state events that should be sent to clients when their user is
  invited to a room.
  """
  alias RadioBeam.Room.PDU

  defstruct mapping: %{}

  @type t() :: %__MODULE__{mapping: %{{type :: String.t(), state_key :: String.t()} => PDU.t()}}

  def new!(), do: %__MODULE__{}

  def key_for(room_id, _pdu), do: {:ok, {__MODULE__, room_id}}

  @stripped_state_types Enum.map(
                          ~w|create member name avatar topic join_rules canonical_alias encryption|,
                          &"m.room.#{&1}"
                        )
  def stripped_state_types, do: @stripped_state_types

  def handle_pdu(%__MODULE__{} = invite_state, _room_id, _state_mapping, %PDU{event: %{type: type}} = pdu)
      when type in @stripped_state_types do
    if type == "m.room.member" and pdu.event.content["membership"] != "invite" do
      {_, invite_state} = pop_in(invite_state.mapping[{type, pdu.event.state_key}])
      invite_state
    else
      put_in(invite_state.mapping[{type, pdu.event.state_key}], pdu)
    end
  end

  def handle_pdu(%__MODULE__{} = invite_state, _room_id, _state_mapping, _pdu), do: invite_state
end
