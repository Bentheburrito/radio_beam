defmodule RadioBeamWeb.HomeserverInfoControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeamWeb.HomeserverInfoController

  test "versions/0", %{conn: conn} do
    resp = HomeserverInfoController.versions(conn, %{})
    assert resp.resp_body =~ ~s|"versions":[|
  end
end
