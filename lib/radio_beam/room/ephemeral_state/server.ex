defmodule RadioBeam.Room.EphemeralState.Server do
  @moduledoc false
  use GenServer

  alias RadioBeam.PubSub
  alias RadioBeam.Room.EphemeralState.Core
  alias RadioBeam.Room.EphemeralState.Server.Supervisor

  @registry RadioBeam.RoomEphemeralStateRegistry

  @enforce_keys [:room_id]
  defstruct room_id: nil, ephemeral_state: Core.new!()

  ### API ###

  def start_link("!" <> _ = room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via(room_id))
  end

  def put_typing(room_id, user_id, timeout), do: call(room_id, {:put_typing, user_id, timeout})

  def all_typing(room_id), do: call(room_id, :all_typing)

  def delete_typing(room_id, user_id), do: call(room_id, {:delete_typing, user_id})

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
      with {:error, {:already_started, pid}} <- Supervisor.start_ephemeral_state_server(room_id), do: {:ok, pid}
    else
      {:error, :not_found}
    end
  end

  ### IMPL ###

  @impl GenServer
  def init(room_id), do: {:ok, %__MODULE__{room_id: room_id}}

  @impl GenServer
  def handle_call(:all_typing, _from, %__MODULE__{} = state),
    do: {:reply, Core.all_typing(state.ephemeral_state), state}

  @impl GenServer
  def handle_call({:put_typing, user_id, timeout}, _from, %__MODULE__{} = state) do
    ephemeral_state = Core.put_typing(state.ephemeral_state, user_id, timeout)
    broadcast(state.room_id, ephemeral_state)
    {:reply, :ok, put_in(state.ephemeral_state, ephemeral_state)}
  end

  @impl GenServer
  def handle_call({:delete_typing, user_id}, _from, %__MODULE__{} = state) do
    ephemeral_state = Core.delete_typing(state.ephemeral_state, user_id)
    broadcast(state.room_id, state.ephemeral_state)
    {:reply, :ok, put_in(state.ephemeral_state, ephemeral_state)}
  end

  @impl GenServer
  def handle_info({:delete_typing, user_id}, %__MODULE__{} = state) do
    ephemeral_state = Core.delete_typing(state.ephemeral_state, user_id)
    broadcast(state.room_id, ephemeral_state)
    {:noreply, put_in(state.ephemeral_state, ephemeral_state)}
  end

  defp broadcast(room_id, state),
    do: PubSub.broadcast(PubSub.all_room_events(room_id), {:room_ephemeral_state_update, room_id, state})

  defp via(room_id), do: {:via, Registry, {@registry, room_id}}
end
