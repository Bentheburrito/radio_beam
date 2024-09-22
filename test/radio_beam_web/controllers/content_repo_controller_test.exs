defmodule RadioBeamWeb.ContentRepoControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  setup %{conn: conn} do
    user1 = Fixtures.user()
    device = Fixtures.device(user1.id, "da steam deck")

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"),
      user: user1,
      device: device
    }
  end

  describe "config/2" do
    test "returns an object (200) with the m.upload.size key", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v1/media/config", %{})
      assert %{"m.upload.size" => _} = json_response(conn, 200)
    end
  end

  describe "upload/2" do
    test "accepts (200) an appropriately sized upload of an accepted type", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/csv")
        |> post(~p"/_matrix/media/v3/upload", "A,B,C\nval1,val2,val3")

      server_name = RadioBeam.server_name()
      assert %{"content_uri" => "mxc://" <> ^server_name <> "/" <> _} = json_response(conn, 200)
    end

    test "rejects (401) an upload if an access token is not provided", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> put_req_header("content-type", "text/csv")
        |> post(~p"/_matrix/media/v3/upload", "A,B,C\nval1,val2,val3")

      assert %{"errcode" => "M_MISSING_TOKEN"} = json_response(conn, 401)
    end
  end
end
