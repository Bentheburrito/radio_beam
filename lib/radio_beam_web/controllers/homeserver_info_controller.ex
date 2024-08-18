defmodule RadioBeamWeb.HomeserverInfoController do
  use RadioBeamWeb, :controller

  def home(conn, _params) do
    conn
    |> put_status(200)
    |> text("RadioBeam is up and running")
  end

  def capabilities(conn, _params) do
    json(conn, %{capabilities: Application.fetch_env!(:radio_beam, :capabilities)})
  end

  def versions(conn, _params) do
    json(conn, Application.fetch_env!(:radio_beam, :versions))
  end

  def login_types(conn, _params) do
    json(conn, Application.fetch_env!(:radio_beam, :login_types))
  end

  def well_known_client(conn, _params) do
    json(conn, Application.get_env(:radio_beam, :well_known_client, %{"m.homeserver" => RadioBeam.server_name()}))
  end
end
