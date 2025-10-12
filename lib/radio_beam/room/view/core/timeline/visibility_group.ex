defmodule RadioBeam.Room.View.Core.Timeline.VisibilityGroup do
  defstruct ~w|joined invited history_visibility|a

  alias RadioBeam.Room
  alias RadioBeam.Room.PDU

  def from_state!(state, pdu) do
    init_group =
      case Room.State.fetch_at(state, "m.room.history_visibility", pdu) do
        {:ok, %PDU{} = pdu} -> %__MODULE__{history_visibility: pdu.event.content["history_visibility"]}
        {:error, :not_found} -> %__MODULE__{history_visibility: "shared"}
      end

    state
    |> Room.State.get_all_at(pdu)
    |> Enum.reduce(init_group, fn
      {{"m.room.member", user_id}, %PDU{event: %{state_key: user_id}} = pdu}, %__MODULE__{} = group ->
        case pdu.event.content["membership"] do
          "join" -> put_in(group.joined, user_id)
          "invite" -> put_in(group.invited, user_id)
          _ -> group
        end

      _, group ->
        group
    end)
  end

  def id(%__MODULE__{history_visibility: "world_readable"}), do: :world_readable
  def id(%__MODULE__{} = group), do: :crypto.hash(:sha256, :erlang.term_to_binary(group))
end
