defmodule RadioBeam.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    Logger.info("Initializing Mnesia...")
    db_init_result = RadioBeam.Repo.init_mnesia()
    Logger.info("Mnesia init finished with result: #{inspect(db_init_result)}")

    children = [
      RadioBeamWeb.Telemetry,
      # RadioBeam.Repo,
      {DNSCluster, query: Application.get_env(:radio_beam, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RadioBeam.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: RadioBeam.Finch},
      # Start the RoomRegistry
      {Registry, keys: :unique, name: RadioBeam.RoomRegistry},
      # Start the GenServer that handles transaction IDs
      RadioBeam.Transaction,
      # Start the RoomSupervisor
      {DynamicSupervisor, name: RadioBeam.RoomSupervisor},
      # Start to serve requests, typically the last entry
      RadioBeamWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RadioBeam.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl Application
  def config_change(changed, _new, removed) do
    RadioBeamWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
