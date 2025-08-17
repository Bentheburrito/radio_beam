defmodule RadioBeam.Room.Server.Supervisor do
  @moduledoc """
  Dynamically creates and revives `RadioBeam.Room.Server`s under its
  supervision.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_room(%RadioBeam.Room{} = room) do
    DynamicSupervisor.start_child(__MODULE__, {RadioBeam.Room.Server, room})
  end
end
