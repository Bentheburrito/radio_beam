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
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc123", %{})

      assert %{"errcode" => "M_BAD_JSON"} = json_response(conn, 400)
    end

    test "(tochange): returns M_UNRECOGNIZED (404) when a user is not on the same homserver", %{conn: conn} do
      messages = %{"@test:somewhere.else" => %{"idontexist" => %{"hello" => "world"}}}
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc123", %{"messages" => messages})

      assert %{"errcode" => "M_UNRECOGNIZED"} = json_response(conn, 404)
    end

    @tag :capture_log
    test "returns M_UNKNOWN (500) and cleanly aborts the transaction when put_many fails", %{conn: conn, user: user} do
      messages = %{user.id => %{"idontexist" => %{"hello" => "world"}}}
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/xyz123", %{"messages" => messages})

      assert %{"errcode" => "M_UNKNOWN"} = json_response(conn, 500)
      # if this doesn't hang, the txn must have been aborted
      assert {:ok, _handle} =
               RadioBeam.Transaction.begin("xyz123", "idontexist", "/_matrix/client/v3/sendToDevice/m.what/xyz123")
    end

    test "rejects an incomplete request body with M_BAD_JSON (400)", %{conn: conn} do
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc123", %{})

      assert %{"errcode" => "M_BAD_JSON"} = json_response(conn, 400)

      messages = %{}
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc123", %{"messages" => messages})
      assert %{"errcode" => "M_BAD_JSON"} = json_response(conn, 400)
    end
  end
end
