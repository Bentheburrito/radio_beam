defmodule RadioBeamApplication do
  @moduledoc false

  use Application
  use Boundary, deps: [RadioBeam, RadioBeamWeb]

  require Logger

  @impl Application
  def start(_type, _args) do
    children = RadioBeam.application_children() ++ RadioBeamWeb.application_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RadioBeam.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl Application
  def config_change(changed, new, removed) do
    RadioBeam.config_change(changed, new, removed)
    RadioBeamWeb.config_change(changed, new, removed)
    :ok
  end
end
