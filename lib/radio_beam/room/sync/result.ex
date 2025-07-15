defmodule RadioBeam.Room.Sync.Result do
  alias RadioBeam.PDU
  alias RadioBeam.Room.Sync.Core.InvitedRoomResult
  alias RadioBeam.Room.Sync.Core.JoinedRoomResult

  defstruct data: [], next_batch_pdu_by_room_id: %{}

  @type t() :: %__MODULE__{
          data: [JoinedRoomResult.t() | InvitedRoomResult.t()],
          next_batch_pdu_by_room_id: %{Room.id() => PDU.event_id()}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec put_result(
          t(),
          :no_update | JoinedRoomResult.t() | InvitedRoomResult.t(),
          Room.id(),
          maybe_last_pdu :: PDU.t() | nil
        ) :: t()
  def put_result(sync_result, :no_update, room_id, maybe_last_pdu),
    do: update_in(sync_result.next_batch_pdu_by_room_id, &put_next_batch_pdu(&1, room_id, maybe_last_pdu))

  def put_result(sync_result, room_sync_result, room_id, maybe_last_pdu) do
    struct!(sync_result,
      data: [room_sync_result | sync_result.data],
      next_batch_pdu_by_room_id: put_next_batch_pdu(sync_result.next_batch_pdu_by_room_id, room_id, maybe_last_pdu)
    )
  end

  defp put_next_batch_pdu(next_batch_pdus_by_room_id, _room_id, nil), do: next_batch_pdus_by_room_id

  defp put_next_batch_pdu(next_batch_pdus_by_room_id, room_id, %PDU{} = last_pdu),
    do: Map.put(next_batch_pdus_by_room_id, room_id, last_pdu)

  defimpl Jason.Encoder do
    alias RadioBeam.Room.Sync

    @room_sync_init_acc %{"join" => %{}, "invite" => %{}, "knock" => %{}, "leave" => %{}}
    def encode(%Sync.Result{} = sync_result, opts) do
      rooms_to_encode =
        Enum.reduce(sync_result.data, @room_sync_init_acc, fn
          %Sync.JoinedRoomResult{} = room_result, to_encode_map ->
            put_in(to_encode_map, [room_result.current_membership, room_result.room_id], room_result)

          %Sync.InvitedRoomResult{} = room_result, to_encode_map ->
            put_in(to_encode_map, ["invite", room_result.room_id], room_result)

          :no_update, to_encode_map ->
            to_encode_map
        end)

      Jason.Encode.map(rooms_to_encode, opts)
    end
  end
end
