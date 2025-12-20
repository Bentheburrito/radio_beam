defmodule RadioBeamWeb.ClientControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  @moduletag [device_display_name: "da steam deck"]

  describe "get_device/2" do
    test "returns a list of devices", %{conn: conn, device: device} do
      conn = get(conn, ~p"/_matrix/client/v3/devices", %{})

      expected_device = %{"device_id" => device.id, "display_name" => "da steam deck", "last_seen_ip" => "127.0.0.1"}
      assert %{"devices" => [actual_device]} = json_response(conn, 200)
      assert ^expected_device = Map.delete(actual_device, "last_seen_ts")
    end

    test "returns a device under the given device ID", %{conn: conn, device: device} do
      conn = get(conn, ~p"/_matrix/client/v3/devices/#{device.id}", %{})

      expected_device = %{"device_id" => device.id, "display_name" => "da steam deck", "last_seen_ip" => "127.0.0.1"}
      assert actual_device = json_response(conn, 200)
      assert ^expected_device = Map.delete(actual_device, "last_seen_ts")
    end

    test "returns M_NOT_FOUND (404) when the device ID is not known", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v3/devices/asdfasdfasdf", %{})

      assert %{"errcode" => "M_NOT_FOUND", "error" => "no device by that ID"} = json_response(conn, 404)
    end
  end

  describe "put_device_display_name/2" do
    test "returns empty object (200) when given a new display name", %{conn: conn, device: device} do
      conn = put(conn, ~p"/_matrix/client/v3/devices/#{device.id}", %{"display_name" => "da steam machine"})

      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns empty object (200) even when no new display name is given", %{conn: conn, device: device} do
      conn = put(conn, ~p"/_matrix/client/v3/devices/#{device.id}", %{})

      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end
  end

  describe "send_to_device/2" do
    test "returns an empty object on success (200)", %{conn: conn, user: user, device: device} do
      messages = %{
        user.id => %{
          device.id => %{"content" => %{"hello" => "world"}, "sender" => user.id, "type" => "org.some.hello"}
        }
      }

      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc", %{"messages" => messages})

      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns an empty object (200) when no messages are provided", %{conn: conn} do
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc123", %{"messages" => %{}})

      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    # TOFIX: send to-device msgs over federation
    @tag :skip
    test "(tochange): returns M_UNRECOGNIZED (404) when a user is not on the same homserver", %{conn: conn} do
      messages = %{"@test:somewhere.else" => %{"idontexist" => %{"hello" => "world"}}}
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc123", %{"messages" => messages})

      assert %{"errcode" => "M_UNRECOGNIZED"} = json_response(conn, 404)
    end

    @tag :capture_log
    test "returns M_BAD_JSON (400) and cleanly aborts the transaction when a device is not found", %{
      conn: conn,
      user: user,
      device: device
    } do
      message = %{"content" => %{"hello" => "world"}, "sender" => user.id, "type" => "org.some.hello"}

      messages = %{
        user.id => %{
          device.id => message,
          "idontexist" => message
        }
      }

      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/xyz123", %{"messages" => messages})

      assert %{"errcode" => "M_BAD_JSON"} = json_response(conn, 400)
      # if this doesn't hang, the txn must have been aborted
      assert {:ok, _handle} =
               RadioBeam.Transaction.begin("xyz123", "idontexist", "/_matrix/client/v3/sendToDevice/m.what/xyz123")
    end

    test "rejects an invalid request body with M_BAD_JSON (400)", %{conn: conn} do
      messages = %{"notauserid" => %{}}
      conn = put(conn, ~p"/_matrix/client/v3/sendToDevice/m.what/abc123", %{"messages" => messages})
      assert %{"errcode" => "M_BAD_JSON"} = json_response(conn, 400)
    end
  end
end
