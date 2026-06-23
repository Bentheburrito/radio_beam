defmodule RadioBeam.Room.Timeline.Acknowledgements.Server.Supervisor do
  @moduledoc """
  Dynamically creates and revives
  `RadioBeam.Room.Timeline.Acknowledgements.Server`s under its supervision.
  """
  use DynamicSupervisor

  def start_link(init_arg), do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl DynamicSupervisor
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_acks_server(room_id),
    do: DynamicSupervisor.start_child(__MODULE__, {RadioBeam.Room.Timeline.Acknowledgements.Server, room_id})
end
