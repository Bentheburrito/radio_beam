defmodule RadioBeamWeb.OAuth2ControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  describe "whoami/2" do
    test "successfully gets a known users's info", %{
      conn: conn,
      device: %{id: device_id},
      account: %{user_id: user_id}
    } do
      conn = get(conn, ~p"/_matrix/client/v3/account/whoami", %{})

      assert %{"device_id" => ^device_id, "user_id" => ^user_id} = json_response(conn, 200)
    end

    test "returns 401 for an unknown access token", %{conn: conn} do
      assert %{"errcode" => "M_UNKNOWN_TOKEN"} =
               conn
               |> put_req_header("authorization", "Bearer blahblahblah")
               |> get(~p"/_matrix/client/v3/account/whoami", %{})
               |> json_response(401)
    end
  end
end
