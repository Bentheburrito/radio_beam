defmodule RadioBeamWeb.KeysControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.User
  alias RadioBeam.User.Auth
  alias RadioBeam.User.Keys

  setup %{conn: conn} do
    {user1, device} = Fixtures.device(Fixtures.user(), "da steam deck")
    %{access_token: token} = Auth.session_info(user1, device)

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{token}"),
      user: user1,
      device: device
    }
  end

  describe "changes/2" do
    test "returns users who have made changes to their keys", %{conn: conn, user: user} do
      {user, user_device} = Fixtures.device(user)
      {someone, device} = Fixtures.device(Fixtures.user())
      {:ok, room_id} = RadioBeam.Room.create(someone)
      %{next_batch: since} = RadioBeam.Room.Timeline.sync([room_id], user.id, user_device.id)

      {:ok, _} = RadioBeam.Room.invite(room_id, someone.id, user.id)
      {:ok, _} = RadioBeam.Room.join(room_id, user.id)
      {someone, _device} = Fixtures.create_and_put_device_keys(someone, device)

      since_encoded = RadioBeam.Room.EventGraph.PaginationToken.encode(since)
      conn = get(conn, ~p"/_matrix/client/v3/keys/changes?from=#{since_encoded}", %{})

      someone_id = someone.id
      assert %{"changed" => [^someone_id], "left" => []} = json_response(conn, 200)
    end
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

  describe "upload_cross_signing/2" do
    test "returns an empty object (200) when the keys pass all checks and are successfully uploaded", %{
      conn: conn,
      user: user
    } do
      conn = post(conn, ~p"/_matrix/client/v3/keys/device_signing/upload", csk_request(user.id))

      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns M_INVALID_PARAM (400) when the device/user do not match the access ID", %{conn: conn} do
      user = Fixtures.user()

      conn = post(conn, ~p"/_matrix/client/v3/keys/device_signing/upload", csk_request(user.id))

      assert %{"errcode" => "M_INVALID_PARAM", "error" => error} = json_response(conn, 400)
      assert error =~ "do not match the owner of the device"
    end

    defp csk_request(user_id) do
      master_key_id = "base64masterpublickey"
      {master_pubkey, master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      master_key = %{
        "keys" => %{("ed25519:" <> master_key_id) => Base.encode64(master_pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => user_id
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
            "user_id" => user_id
          },
          user_id,
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
            "user_id" => user_id
          },
          user_id,
          master_signingkey
        )

      %{
        master_key: master_key,
        self_signing_key: self_signing_key,
        user_signing_key: user_signing_key
      }
    end
  end

  describe "upload_signatures/2" do
    setup %{user: user, device: device} do
      {csks, privkeys} = Fixtures.create_cross_signing_keys(user.id)
      {:ok, user} = User.CrossSigningKeyRing.put(user.id, csks)

      {device_key, device_signingkey} = Fixtures.device_keys(device.id, user.id)
      {:ok, user} = Keys.put_device_keys(user.id, device.id, identity_keys: device_key)
      {:ok, device} = User.get_device(user, device.id)

      %{user: user, device: device, user_priv_csks: privkeys, device_signingkey: device_signingkey}
    end

    test "returns an empty object (200) when the signatures are successfully uploaded", %{
      conn: conn,
      device_signingkey: device_signingkey,
      user: user
    } do
      master_key = User.CrossSigningKey.to_map(user.cross_signing_key_ring.master, user.id)
      master_pubkeyb64 = master_key["keys"] |> Map.values() |> hd()

      {:ok, master_key} = Polyjuice.Util.JSON.sign(master_key, user.id, device_signingkey)

      request_body = %{user.id => %{master_pubkeyb64 => master_key}}
      conn = post(conn, ~p"/_matrix/client/v3/keys/signatures/upload", request_body)

      assert %{} = failures = json_response(conn, 200)
      assert 0 = map_size(failures)
    end

    test "returns a failures object (200) if the uploaded signature is invalid", %{
      conn: conn,
      user: user,
      device: device
    } do
      {_random, random_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      device_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(random_privkey, padding: false), device.id)

      master_key = User.CrossSigningKey.to_map(user.cross_signing_key_ring.master, user.id)
      master_pubkeyb64 = master_key["keys"] |> Map.values() |> hd()

      {:ok, master_key} = Polyjuice.Util.JSON.sign(master_key, user.id, device_signingkey)

      request_body = %{user.id => %{master_pubkeyb64 => master_key}}
      conn = post(conn, ~p"/_matrix/client/v3/keys/signatures/upload", request_body)

      assert %{} = failures = json_response(conn, 200)
      assert 1 = map_size(failures)
      assert %{"errcode" => "M_INVALID_SIGNATURE", "error" => error} = failures["failures"][user.id][master_pubkeyb64]
      assert error =~ "signature failed verification"
    end
  end

  describe "claim/2" do
    test "returns a one-time key (200) that matches the given query", %{conn: conn, user: user, device: device} do
      {:ok, _device} = Keys.put_device_keys(user.id, device.id, one_time_keys: @otk_keys)

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

  describe "query/2" do
    test "returns the queried keys (200)", %{conn: conn} do
      %{id: user_id} = user = Fixtures.user()
      {cross_signing_keys, _privkeys} = Fixtures.create_cross_signing_keys(user.id)
      {:ok, user} = RadioBeam.User.CrossSigningKeyRing.put(user.id, cross_signing_keys)

      {user, %{id: device_id} = device} = Fixtures.device(user)
      {device_key, _signingkey} = Fixtures.device_keys(device.id, user.id)
      {:ok, _device} = Keys.put_device_keys(user.id, device.id, identity_keys: device_key)
      conn = post(conn, ~p"/_matrix/client/v3/keys/query", %{device_keys: %{user.id => []}})

      assert %{} = response = json_response(conn, 200)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = response["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = response["self_signing_keys"]
      refute is_map_key(response, "user_signing_keys")
      assert %{^user_id => %{^device_id => %{}}} = response["device_keys"]
    end
  end
end
