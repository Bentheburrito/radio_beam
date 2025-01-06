defmodule RadioBeamWeb.KeysControllerTest do
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
    test "returns the count (200) of new one-time keys uploaded", %{conn: conn} do
      conn = post(conn, ~p"/_matrix/client/v3/keys/upload", %{one_time_keys: @otk_keys})
      assert %{"one_time_key_counts" => %{"signed_curve25519" => 2}} = json_response(conn, 200)
    end
  end

  describe "upload_signing/2" do
    test "returns an empty object (200) when the keys pass all checks and are successfully uploaded", %{
      conn: conn,
      device: device
    } do
      conn = post(conn, ~p"/_matrix/client/v3/keys/device_signing/upload", csk_request(device))

      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns M_INVALID_PARAM (400) when the device/user do not match the access ID", %{conn: conn} do
      user = Fixtures.user()
      device = Fixtures.device(user.id)

      conn = post(conn, ~p"/_matrix/client/v3/keys/device_signing/upload", csk_request(device))

      assert %{"errcode" => "M_INVALID_PARAM", "error" => error} = json_response(conn, 400)
      assert error =~ "do not match the owner of the device"
    end

    defp csk_request(device) do
      master_key_id = "base64masterpublickey"
      {master_pubkey, master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      master_key = %{
        "keys" => %{("ed25519:" <> master_key_id) => Base.encode64(master_pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => device.user_id
      }

      master_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(master_privkey, padding: false), master_key_id)

      {:ok, self_signing_key} =
        Polyjuice.Util.JSON.sign(
          %{
            "keys" => %{
              "ed25519:base64selfsigningpublickey" =>
                Base.encode64("base64+self+signing+master+public+key", padding: false)
            },
            "usage" => ["self_signing"],
            "user_id" => device.user_id
          },
          device.user_id,
          master_signingkey
        )

      {:ok, user_signing_key} =
        Polyjuice.Util.JSON.sign(
          %{
            "keys" => %{
              "ed25519:base64usersigningpublickey" =>
                Base.encode64("base64+user+signing+master+public+key", padding: false)
            },
            "usage" => ["user_signing"],
            "user_id" => device.user_id
          },
          device.user_id,
          master_signingkey
        )

      %{
        master_key: master_key,
        self_signing_key: self_signing_key,
        user_signing_key: user_signing_key
      }
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
