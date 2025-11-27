defmodule RadioBeam.Room.Sync.Result do
  alias RadioBeam.Room.Sync.Core.InvitedRoomResult
  alias RadioBeam.Room.Sync.Core.JoinedRoomResult

  defstruct data: [], next_batch_map: %{}

  @type t() :: %__MODULE__{
          data: [JoinedRoomResult.t() | InvitedRoomResult.t()],
          next_batch_map: %{Room.id() => Room.event_id()}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec put_result(
          t(),
          :no_update | JoinedRoomResult.t() | InvitedRoomResult.t(),
          Room.id(),
          maybe_last_event_id :: Room.event_id() | nil
        ) :: t()
  def put_result(sync_result, :no_update, room_id, maybe_last_event_id),
    do: update_in(sync_result.next_batch_map, &put_next_batch_pdu(&1, room_id, maybe_last_event_id))

  def put_result(sync_result, room_sync_result, room_id, maybe_last_event_id) do
    struct!(sync_result,
      data: [room_sync_result | sync_result.data],
      next_batch_map: put_next_batch_pdu(sync_result.next_batch_map, room_id, maybe_last_event_id)
    )
  end

  defp put_next_batch_pdu(next_batch_map, _room_id, nil), do: next_batch_map

  defp put_next_batch_pdu(next_batch_map, room_id, last_event_id),
    do: Map.put(next_batch_map, room_id, last_event_id)

  defimpl JSON.Encoder do
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

      JSON.Encoder.Map.encode(rooms_to_encode, opts)
    end
  end
end
