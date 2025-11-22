defmodule RadioBeam.Room.EphemeralState.Server do
  use GenServer

  alias RadioBeam.PubSub
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Room.EphemeralState
  alias RadioBeam.Room.EphemeralState.Core
  alias RadioBeam.Room.EphemeralState.Server.Supervisor

  @registry RadioBeam.RoomEphemeralStateRegistry

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
    if RadioBeam.Room.exists?(room_id) do
      case Registry.lookup(@registry, room_id) do
        [{pid, _}] -> {:ok, pid}
        _ -> with {:error, {:already_started, pid}} <- Supervisor.start_ephemeral_state_server(room_id), do: {:ok, pid}
      end
    else
      {:error, :not_found}
    end
  end

  ### IMPL ###

  @impl GenServer
  def init(room_id) do
    PubSub.subscribe(PubSub.all_room_events(room_id))
    {:ok, {room_id, Core.new!()}}
  end

  @impl GenServer
  def handle_call(:all_typing, _from, {room_id, %EphemeralState{} = state}),
    do: {:reply, Core.all_typing(state), {room_id, state}}

  @impl GenServer
  def handle_call({:put_typing, user_id, timeout}, _from, {room_id, %EphemeralState{} = state}) do
    state = Core.put_typing(state, user_id, timeout)
    broadcast(room_id, state)
    {:reply, state, {room_id, state}}
  end

  @impl GenServer
  def handle_call({:delete_typing, user_id}, _from, {room_id, %EphemeralState{} = state}) do
    state = Core.delete_typing(state, user_id)
    broadcast(room_id, state)
    {:reply, state, {room_id, state}}
  end

  @impl GenServer
  def handle_info({:delete_typing, user_id}, {room_id, %EphemeralState{} = state}) do
    state = Core.delete_typing(state, user_id)
    broadcast(room_id, state)
    {:noreply, {room_id, state}}
  end

  @impl GenServer
  def handle_info({:room_event, room_id, %Event{} = event}, {room_id, %EphemeralState{} = state}) do
    state = Core.delete_typing(state, event.sender)
    broadcast(room_id, state)
    {:noreply, {room_id, state}}
  end

  @impl GenServer
  def handle_info({:room_ephemeral_state_update, room_id, _}, {room_id, state}), do: {:noreply, {room_id, state}}

  defp broadcast(room_id, state),
    do: PubSub.broadcast(PubSub.all_room_events(room_id), {:room_ephemeral_state_update, room_id, state})

  defp via(room_id), do: {:via, Registry, {@registry, room_id}}
end
