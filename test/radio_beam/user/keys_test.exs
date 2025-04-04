defmodule RadioBeam.User.KeysTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User
  alias RadioBeam.User.CrossSigningKey
  alias RadioBeam.User.Device
  alias RadioBeam.User.Keys

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
  @fallback_key %{
    "signed_curve25519:AAAAGj" => %{
      "fallback" => true,
      "key" => "fallback1",
      "signatures" => %{
        "@alice:example.com" => %{
          "ed25519:JLAFKJWSCS" =>
            "FLWxXqGbwrb8SM3Y795eB6OA8bwBcoMZFXBqnTn58AYWZSqiD45tlBVcDa2L7RwdKXebW/VzDlnfVJ+9jok1Bw"
        }
      }
    }
  }
  describe "put_device_keys/3" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "adds the given one-time keys to a device", %{user: user, device: device} do
      {:ok, user} = Keys.put_device_keys(user, device.id, one_time_keys: @otk_keys)
      {:ok, device} = User.get_device(user, device.id)

      assert %{"signed_curve25519" => 2} = Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring)
    end

    @fallback_key %{
      "signed_curve25519:AAAAGj" => %{
        "fallback" => true,
        "key" => "fallback1",
        "signatures" => %{
          "@alice:example.com" => %{
            "ed25519:JLAFKJWSCS" =>
              "FLWxXqGbwrb8SM3Y795eB6OA8bwBcoMZFXBqnTn58AYWZSqiD45tlBVcDa2L7RwdKXebW/VzDlnfVJ+9jok1Bw"
          }
        }
      }
    }
    test "adds the given fallback key to a device", %{user: user, device: device} do
      {:ok, user} = Keys.put_device_keys(user, device.id, fallback_keys: @fallback_key)
      {:ok, device} = User.get_device(user, device.id)

      assert {:ok, {%{"key" => "fallback1"}, _}} =
               Device.OneTimeKeyRing.claim_otk(device.one_time_key_ring, "signed_curve25519")
    end

    test "adds the given device identity keys to a device", %{user: user, device: device} do
      {device_key, _signingkey} = Fixtures.device_keys(device.id, user.id)

      {:ok, user} = Keys.put_device_keys(user, device.id, identity_keys: device_key)

      {:ok, device} = User.get_device(user, device.id)

      expected_ed_key = "ed25519:#{device.id}"
      expected_ed_value = device_key["keys"] |> Map.values() |> hd()

      assert %{"keys" => %{^expected_ed_key => ^expected_ed_value}} = device.identity_keys
    end

    test "errors when the user or device ID on the given device identity keys map don't match the device's ID or its owner's user ID",
         %{user: user, device: device} do
      for device_id <- ["blah", device.id],
          user_id <- ["blah", user.id],
          device_id != device.id or user_id != user.id do
        {device_key, _signingkey} = Fixtures.device_keys(device_id, user_id)

        assert {:error, :invalid_identity_keys} =
                 Keys.put_device_keys(user, device.id, identity_keys: device_key)
      end
    end
  end

  describe "query_all/2" do
    test "returns all cross-signing and device identity keys if the user is querying their own keys" do
      %{id: user_id} = user = Fixtures.user()
      {cross_signing_keys, _privkeys} = Fixtures.create_cross_signing_keys(user.id)
      {:ok, user} = User.CrossSigningKeyRing.put(user.id, cross_signing_keys)

      assert %{} = query_result = Keys.query_all(%{user.id => []}, user.id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["user_signing"]}} = query_result["user_signing_keys"]

      {user, %{id: device_id} = device} = Fixtures.device(user)
      {device_key, _signingkey} = Fixtures.device_keys(device.id, user.id)
      {:ok, _device} = Keys.put_device_keys(user, device.id, identity_keys: device_key)
      assert %{} = query_result = Keys.query_all(%{user.id => []}, user.id)

      assert %{
               ^user_id => %{
                 ^device_id => %{
                   "user_id" => ^user_id,
                   "device_id" => ^device_id,
                   "keys" => %{("ed25519:" <> ^device_id) => _}
                 }
               }
             } = query_result["device_keys"]
    end

    test "returns all cross-signing keys (except user-signing) when querying someone else's keys" do
      querying = Fixtures.user()
      %{id: user_id} = user = Fixtures.user()
      {cross_signing_keys, _privkeys} = Fixtures.create_cross_signing_keys(user.id)
      {:ok, user} = User.CrossSigningKeyRing.put(user.id, cross_signing_keys)

      assert %{} = query_result = Keys.query_all(%{user.id => []}, querying.id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      refute is_map_key(query_result, "user_signing_keys")

      {user, %{id: device_id} = device} = Fixtures.device(user)
      {device_key, _signingkey} = Fixtures.device_keys(device.id, user.id)
      {:ok, user} = Keys.put_device_keys(user, device.id, identity_keys: device_key)
      assert %{} = query_result = Keys.query_all(%{user.id => []}, querying.id)

      assert %{
               ^user_id => %{
                 ^device_id => %{
                   "user_id" => ^user_id,
                   "device_id" => ^device_id,
                   "keys" => %{("ed25519:" <> ^device_id) => _}
                 }
               }
             } = query_result["device_keys"]
    end

    test "properly filters device keys by the given device IDs, but returns all device keys given an empty list" do
      querying = Fixtures.user()

      %{id: user_id} = user = Fixtures.user()
      {user, %{id: device_id1} = device1} = Fixtures.device(user)
      {user, %{id: device_id2} = device2} = Fixtures.device(user)
      {user, %{id: device_id3} = device3} = Fixtures.device(user)

      {device1_key, _signingkey} = Fixtures.device_keys(device1.id, user.id)
      {device2_key, _signingkey} = Fixtures.device_keys(device2.id, user.id)
      {device3_key, _signingkey} = Fixtures.device_keys(device3.id, user.id)
      {:ok, user} = Keys.put_device_keys(user, device1.id, identity_keys: device1_key)
      {:ok, user} = Keys.put_device_keys(user, device2.id, identity_keys: device2_key)
      {:ok, user} = Keys.put_device_keys(user, device3.id, identity_keys: device3_key)
      assert %{} = query_result = Keys.query_all(%{user.id => []}, querying.id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 3 = map_size(device_keys_map)

      assert %{} = query_result = Keys.query_all(%{user.id => [device_id1, device_id3]}, querying.id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 2 = map_size(device_keys_map)
      refute Enum.any?(device_keys_map, fn {device_id, _} -> device_id == device_id2 end)
    end
  end

  describe "put_signatures/2" do
    setup do
      user = Fixtures.user()
      {csks, privkeys} = Fixtures.create_cross_signing_keys(user.id)
      {:ok, user} = User.CrossSigningKeyRing.put(user.id, csks)

      {user, device} = Fixtures.device(user)
      {device_key, device_signingkey} = Fixtures.device_keys(device.id, user.id)
      {:ok, user} = Keys.put_device_keys(user, device.id, identity_keys: device_key)
      {:ok, device} = User.get_device(user, device.id)

      %{user: user, device: device, user_priv_csks: privkeys, device_signingkey: device_signingkey}
    end

    test "puts signatures for the user's MSK made by the user's devices", %{
      user: user,
      device_signingkey: device_signingkey
    } do
      master_key = CrossSigningKey.to_map(user.cross_signing_key_ring.master, user.id)
      master_pubkeyb64 = master_key["keys"] |> Map.values() |> hd()

      {:ok, master_key} = Polyjuice.Util.JSON.sign(master_key, user.id, device_signingkey)

      assert :ok = Keys.put_signatures(user.id, %{user.id => %{master_pubkeyb64 => master_key}})
    end

    test "puts signatures for the user's own device keys", %{user: user, device: device, user_priv_csks: privkeys} do
      self_key = CrossSigningKey.to_map(user.cross_signing_key_ring.self, user.id)
      self_pubkeyb64 = self_key["keys"] |> Map.values() |> hd()

      self_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.self_key, padding: false), self_pubkeyb64)

      {:ok, device_key} = Polyjuice.Util.JSON.sign(device.identity_keys, user.id, self_signingkey)

      assert :ok = Keys.put_signatures(user.id, %{user.id => %{device.id => device_key}})
    end

    test "puts signatures for another user's master CSK", %{user: user, user_priv_csks: privkeys} do
      glerp = Fixtures.user()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.id)
      {:ok, glerp} = User.CrossSigningKeyRing.put(glerp.id, glerp_csks)

      user_key = CrossSigningKey.to_map(user.cross_signing_key_ring.user, user.id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_master_key = Keyword.fetch!(glerp_csks, :master_key)
      glerp_master_pubkeyb64 = glerp_master_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_master_key} = Polyjuice.Util.JSON.sign(glerp_master_key, user.id, user_signingkey)

      assert :ok = Keys.put_signatures(user.id, %{glerp.id => %{glerp_master_pubkeyb64 => glerp_master_key}})
    end

    test "errors with user_ids_do_not_match if CSKs do not belong to the given user" do
      user = Fixtures.user()
      {csks, _privkeys} = Fixtures.create_cross_signing_keys(user.id)

      glerp = Fixtures.user()
      assert {:error, :user_ids_do_not_match} = User.CrossSigningKeyRing.put(glerp.id, csks)
    end

    test "errors with invalid_signature if the signature is bad (device key -> master key)", %{
      user: user,
      device: device
    } do
      {_random, random_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      device_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(random_privkey, padding: false), device.id)

      master_key = CrossSigningKey.to_map(user.cross_signing_key_ring.master, user.id)
      master_pubkeyb64 = master_key["keys"] |> Map.values() |> hd()

      {:ok, master_key} = Polyjuice.Util.JSON.sign(master_key, user.id, device_signingkey)

      assert {:error, failures} = Keys.put_signatures(user.id, %{user.id => %{master_pubkeyb64 => master_key}})
      assert 1 = map_size(failures)
      assert failures[user.id][master_pubkeyb64] == :invalid_signature
    end

    test "errors with invalid_signature if the signature is bad (self-signing key -> device key)", %{
      user: user,
      device: device
    } do
      self_key = CrossSigningKey.to_map(user.cross_signing_key_ring.self, user.id)
      self_pubkeyb64 = self_key["keys"] |> Map.values() |> hd()

      {_random, random_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      self_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(random_privkey, padding: false), self_pubkeyb64)

      {:ok, device_key} = Polyjuice.Util.JSON.sign(device.identity_keys, user.id, self_signingkey)

      assert {:error, failures} = Keys.put_signatures(user.id, %{user.id => %{device.id => device_key}})
      assert 1 = map_size(failures)
      assert failures[user.id][device.id] == :invalid_signature
    end

    test "errors with :disallowed_key_type when a user tries to put a signature on another user's non-MSK key", %{
      user: user,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.user()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.id)
      {:ok, glerp} = User.CrossSigningKeyRing.put(glerp.id, glerp_csks)

      user_key = CrossSigningKey.to_map(user.cross_signing_key_ring.user, user.id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_self_key = Keyword.fetch!(glerp_csks, :self_signing_key)
      glerp_self_pubkeyb64 = glerp_self_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_self_key} = Polyjuice.Util.JSON.sign(glerp_self_key, user.id, user_signingkey)

      assert {:error, failures} = Keys.put_signatures(user.id, %{glerp.id => %{glerp_self_pubkeyb64 => glerp_self_key}})
      assert 1 = map_size(failures)
      assert failures[glerp.id][glerp_self_pubkeyb64] == :disallowed_key_type
    end

    test "errors with :no_master_csk if the user does not have a MSK", %{user: user, user_priv_csks: privkeys} do
      glerp = Fixtures.user()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.id)

      user_key = CrossSigningKey.to_map(user.cross_signing_key_ring.user, user.id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_master_key = Keyword.fetch!(glerp_csks, :master_key)
      glerp_master_pubkeyb64 = glerp_master_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_master_key} = Polyjuice.Util.JSON.sign(glerp_master_key, user.id, user_signingkey)

      assert {:error, failures} =
               Keys.put_signatures(user.id, %{glerp.id => %{glerp_master_pubkeyb64 => glerp_master_key}})

      assert 1 = map_size(failures)
      assert failures[glerp.id][glerp_master_pubkeyb64] == :no_master_csk
    end

    test "errors with :user_not_found when the user does not exist", %{user: user} do
      assert {:error, failures} = Keys.put_signatures(user.id, %{"@whateverman:localhost" => %{"asdf" => %{}}})
      assert 1 = map_size(failures)
      assert failures["@whateverman:localhost"]["asdf"] == :user_not_found
    end

    test "errors with :different_keys if the key included with the new signatures does not match the current key", %{
      user: user,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.user()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.id)
      # persist with a different `usage` value
      new_glerp_csks = put_in(glerp_csks[:master_key]["usage"], ["master", "something else"])
      {:ok, glerp} = User.CrossSigningKeyRing.put(glerp.id, new_glerp_csks)

      user_key = CrossSigningKey.to_map(user.cross_signing_key_ring.user, user.id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_master_key = Keyword.fetch!(glerp_csks, :master_key)
      glerp_master_pubkeyb64 = glerp_master_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_master_key} = Polyjuice.Util.JSON.sign(glerp_master_key, user.id, user_signingkey)

      assert {:error, failures} =
               Keys.put_signatures(user.id, %{glerp.id => %{glerp_master_pubkeyb64 => glerp_master_key}})

      assert 1 = map_size(failures)
      assert failures[glerp.id][glerp_master_pubkeyb64] == :different_keys
    end
  end
end
