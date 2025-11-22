defmodule RadioBeam.Room.EphemeralState.Server.Supervisor do
  @moduledoc """
  Dynamically creates and revives `RadioBeam.Room.EphemeralState.Server`s under
  its supervision.
  """
  use DynamicSupervisor

  def start_link(init_arg), do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl DynamicSupervisor
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_ephemeral_state_server(room_id),
    do: DynamicSupervisor.start_child(__MODULE__, {RadioBeam.Room.EphemeralState.Server, room_id})
end
