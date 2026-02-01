defmodule RadioBeam.Sync.SinkServer.Supervisor do
  @moduledoc """
  Dynamically creates `RadioBeam.Sync.SinkServer`s under its supervision.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_sink({%{} = _inputs, %{} = _sources_by_key} = init_arg) do
    DynamicSupervisor.start_child(__MODULE__, {RadioBeam.Sync.SinkServer, init_arg})
  end
end
