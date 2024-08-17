defmodule RadioBeamWeb.ClientControllerTest do
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

  describe "send_to_device/2" do
    test "returns an empty object on success (200)", %{conn: conn, user: user, device: device} do
      messages = %{user.id => %{device.id => %{"hello" => "world"}}}
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc", %{"messages" => messages})

      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns M_BAD_JSON (400) when no messages are provided", %{conn: conn} do
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc", %{})

      assert %{"errcode" => "M_BAD_JSON"} = json_response(conn, 400)
    end
  end
end
