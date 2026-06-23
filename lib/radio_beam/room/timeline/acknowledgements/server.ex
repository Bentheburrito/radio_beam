defmodule RadioBeam.Room.Timeline.Acknowledgements.Server do
  @moduledoc """
  Holds the state user acknowledgements for a particular room's timeline.
  """
  use GenServer

  alias RadioBeam.PubSub
  alias RadioBeam.Room.Timeline.Acknowledgements.Core.ReceiptBox
  alias RadioBeam.Room.Timeline.Acknowledgements.Server.Supervisor

  @registry RadioBeam.RoomAcknowledgementsRegistry

  @enforce_keys [:room_id]
  defstruct room_id: nil, receipt_box: ReceiptBox.new!()

  ### API ###

  def start_link("!" <> _ = room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via(room_id))
  end

  def put_read_receipt(room_id, user_id, event_id, receipt_type, thread_id) do
    call(room_id, {:put_read_receipt, user_id, event_id, receipt_type, thread_id})
  end

  def get_all_receipts(room_id, user_id, since_ts) do
    call(room_id, {:get_read_receipts, user_id, since_ts})
  end

  defp call(room_id, message) do
    with {:ok, pid} <- lookup_if_room_exists(room_id), do: GenServer.call(pid, message)
  end

  defp lookup_if_room_exists(room_id) do
    case Registry.lookup(@registry, room_id) do
      [{pid, _}] -> {:ok, pid}
      _ -> start_if_room_exists(room_id)
    end
  end

  defp start_if_room_exists(room_id) do
    if RadioBeam.Room.exists?(room_id) do
      with {:error, {:already_started, pid}} <- Supervisor.start_acks_server(room_id), do: {:ok, pid}
    else
      {:error, :not_found}
    end
  end

  ### IMPL ###

  @impl GenServer
  def init(room_id), do: {:ok, %__MODULE__{room_id: room_id}}

  @impl GenServer
  def handle_call({:put_read_receipt, user_id, event_id, type, thread_id}, _from, %__MODULE__{} = state) do
    receipt_box = ReceiptBox.put(state.receipt_box, user_id, event_id, type, thread_id)
    broadcast(state.room_id, state.receipt_box)
    {:reply, :ok, put_in(state.receipt_box, receipt_box)}
  end

  @impl GenServer
  def handle_call({:get_read_receipts, user_id, since_ts}, _from, %__MODULE__{} = state) do
    {:reply, ReceiptBox.get_all(state.receipt_box, user_id, since_ts), state}
  end

  defp broadcast(room_id, receipt_box),
    do: PubSub.broadcast(PubSub.all_room_events(room_id), {:room_ephemeral_state_update, room_id, receipt_box})

  defp via(room_id), do: {:via, Registry, {@registry, room_id}}
end
