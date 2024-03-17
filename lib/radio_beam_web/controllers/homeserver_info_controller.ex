defmodule RadioBeamWeb.HomeserverInfoController do
  use RadioBeamWeb, :controller

  def versions(conn, _params) do
    json(conn, RadioBeam.versions())
  end
end
