defmodule RadioBeamWeb.DeviceKeysControllerTest do
  alias RadioBeam.Device
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

  @otk_keys %{
    "signed_curve25519:AAAAHQ" => %{
      "key" => "key1",
      "signatures" => %{
        "@alice:example.com" => %{
          "ed25519:JLAFKJWSCS" =>
            "IQeCEPb9HFk217cU9kw9EOiusC6kMIkoIRnbnfOh5Oc63S1ghgyjShBGpu34blQomoalCyXWyhaaT3MrLZYQAA"
        }
      }
    },
    "signed_curve25519:AAAAHg" => %{
      "key" => "key2",
      "signatures" => %{
        "@alice:example.com" => %{
          "ed25519:JLAFKJWSCS" =>
            "FLWxXqGbwrb8SM3Y795eB6OA8bwBcoMZFXBqnTn58AYWZSqiD45tlBVcDa2L7RwdKXebW/VzDlnfVJ+9jok1Bw"
        }
      }
    }
  }
  describe "upload/2" do
    test "returns the count (200) of new keys uploaded", %{conn: conn} do
      conn = post(conn, ~p"/_matrix/client/v3/keys/upload", %{one_time_keys: @otk_keys})
      assert %{"one_time_key_counts" => %{"signed_curve25519" => 2}} = json_response(conn, 200)
    end
  end

  describe "claim/2" do
    test "returns a one-time key (200) that matches the given query", %{conn: conn, user: user, device: device} do
      {:ok, _device} = Device.put_keys(user.id, device.id, one_time_keys: @otk_keys)

      conn =
        post(conn, ~p"/_matrix/client/v3/keys/claim", %{
          one_time_keys: %{user.id => %{device.id => "signed_curve25519"}}
        })

      user_id = user.id
      device_id = device.id
      assert %{"one_time_keys" => %{^user_id => %{^device_id => key_obj}}} = json_response(conn, 200)
      [key_obj] = Map.values(key_obj)
      assert key_obj["key"] in ~w|key1 key2|
    end
  end
end
