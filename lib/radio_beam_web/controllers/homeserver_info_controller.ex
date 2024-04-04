defmodule RadioBeamWeb.HomeserverInfoController do
  use RadioBeamWeb, :controller

  def home(conn, _params) do
    conn
    |> put_status(200)
    |> text("RadioBeam is up and running")
  end

  def versions(conn, _params) do
    json(conn, Application.fetch_env!(:radio_beam, :versions))
  end

  def login_types(conn, _params) do
    json(conn, Application.fetch_env!(:radio_beam, :login_types))
  end
end
