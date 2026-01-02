defmodule RadioBeam.User.KeyStoreTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.User
  alias RadioBeam.User.CrossSigningKey
  alias RadioBeam.User.Database
  alias RadioBeam.User.Device
  alias RadioBeam.User.KeyStore
  alias RadioBeam.Room

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
  describe "claim_otks/1" do
    test "ensures a one-time key is only claimed once" do
      %{id: user_id} = user = Fixtures.user()
      {user, device} = Fixtures.device(user)
      device_id = device.id

      algo = "signed_curve25519"

      assert map_size(Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring)) == 0

      {:ok, _otk_counts} =
        User.put_device_keys(user.id, device.id, one_time_keys: @otk_keys, fallback_keys: @fallback_key)

      {:ok, device} = Database.fetch_user_device(user.id, device.id)

      assert %{^algo => 2} = Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring)

      task = Task.async(fn -> KeyStore.claim_otks(%{user.id => %{device.id => algo}}) end)

      assert %{^user_id => %{^device_id => key_id_to_key_obj1}} =
               KeyStore.claim_otks(%{user.id => %{device.id => algo}})

      assert %{^user_id => %{^device_id => key_id_to_key_obj2}} = Task.await(task)

      assert [{^algo <> ":" <> key_id1, key1}] = Map.to_list(key_id_to_key_obj1)
      assert [{^algo <> ":" <> key_id2, key2}] = Map.to_list(key_id_to_key_obj2)

      assert key_id1 != key_id2
      assert key_id1 in ~w|AAAAHQ AAAAHg|
      assert key_id2 in ~w|AAAAHQ AAAAHg|
      assert key1 != key2
      assert key1["key"] in ~w|key1 key2|
      assert key2["key"] in ~w|key1 key2|
    end
  end

  describe "all_changed_since/2" do
    setup do
      creator = Fixtures.user()
      user1 = Fixtures.user()
      user2 = Fixtures.user()

      {user1, user1_device} = Fixtures.device(user1)
      {user2, user2_device} = Fixtures.device(user2)

      {:ok, room_id} = Room.create(creator)
      {:ok, _} = Room.invite(room_id, creator.id, user1.id)
      {:ok, last_event_id} = Room.invite(room_id, creator.id, user2.id)

      %{
        room_id: room_id,
        last_event_id: last_event_id,
        creator: creator,
        user1: user1,
        user2: user2,
        user1_device: user1_device,
        user2_device: user2_device
      }
    end

    @empty MapSet.new()
    test "returns an empty changed/left lists if the user is in no/empty rooms" do
      user = Fixtures.user()
      since_now = PaginationToken.new(%{}, :forward, System.os_time(:millisecond))
      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(user.id, since_now)

      {:ok, room_id} = Room.create(user)
      :pong = Room.Server.ping(room_id)

      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(user.id, since_now)
    end

    test "does not include user's own key updates in changed" do
      before_update = PaginationToken.new(%{}, :forward, System.os_time(:millisecond))

      user = Fixtures.user()
      {user, device} = Fixtures.device(user)
      {:ok, _room_id} = Room.create(user)

      {user, _device} = Fixtures.create_and_put_device_keys(user, device)

      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(user.id, before_update)
    end

    test "returns changed users who have added device identity keys since the given timestamp", %{
      room_id: room_id,
      creator: creator,
      user1: %{id: user1_id} = user1,
      user2: %{id: user2_id} = user2,
      user1_device: user1_device,
      user2_device: user2_device
    } do
      {:ok, _} = Room.join(room_id, user1.id)
      {:ok, event_id} = Room.join(room_id, user2.id)

      Process.sleep(1)

      before_user1_change = PaginationToken.new(room_id, event_id, :forward, System.os_time(:millisecond))

      Process.sleep(1)

      Fixtures.create_and_put_device_keys(user1, user1_device)

      Process.sleep(1)

      after_user1_change = PaginationToken.new(room_id, event_id, :forward, System.os_time(:millisecond))

      Process.sleep(1)

      expected = MapSet.new([user1_id])
      assert %{changed: ^expected, left: @empty} = KeyStore.all_changed_since(creator.id, before_user1_change)
      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(creator.id, after_user1_change)

      Process.sleep(1)

      Fixtures.create_and_put_device_keys(user2, user2_device)
      after_user2_change = PaginationToken.new(room_id, event_id, :forward, System.os_time(:millisecond))

      expected = MapSet.new([user1_id, user2_id])
      assert %{changed: ^expected, left: @empty} = KeyStore.all_changed_since(creator.id, before_user1_change)
      expected = MapSet.new([user2_id])
      assert %{changed: ^expected, left: @empty} = KeyStore.all_changed_since(creator.id, after_user1_change)
      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(creator.id, after_user2_change)
    end

    test "returns changed users who have joined the room since the given timestamp", %{
      room_id: room_id,
      last_event_id: last_event_id,
      creator: creator,
      user1: %{id: user1_id} = user1,
      user2: %{id: user2_id} = user2,
      user1_device: user1_device,
      user2_device: user2_device
    } do
      Fixtures.create_and_put_device_keys(user1, user1_device)
      Fixtures.create_and_put_device_keys(user2, user2_device)

      before_user1_join = PaginationToken.new(room_id, last_event_id, :forward, System.os_time(:millisecond))

      {:ok, event_id} = Room.join(room_id, user1.id)

      after_user1_join = PaginationToken.new(room_id, event_id, :forward, System.os_time(:millisecond))

      expected = MapSet.new([user1_id])
      assert %{changed: ^expected, left: @empty} = KeyStore.all_changed_since(creator.id, before_user1_join)
      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(creator.id, after_user1_join)

      {:ok, event_id} = Room.join(room_id, user2.id)

      after_user2_join = PaginationToken.new(room_id, event_id, :forward, System.os_time(:millisecond))

      expected = MapSet.new([user1_id, user2_id])
      assert %{changed: ^expected, left: @empty} = KeyStore.all_changed_since(creator.id, before_user1_join)
      expected = MapSet.new([user2_id])
      assert %{changed: ^expected, left: @empty} = KeyStore.all_changed_since(creator.id, after_user1_join)
      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(creator.id, after_user2_join)
    end

    test "does not return users for which we do not share a room", %{
      room_id: room_id,
      last_event_id: last_event_id,
      user1: user1,
      user2: user2,
      user1_device: user1_device
    } do
      before_user1_change = PaginationToken.new(room_id, last_event_id, :forward, System.os_time(:millisecond))

      {:ok, _} = Room.join(room_id, user1.id)
      # user2 not joining!
      # {:ok, _} = Room.join(room_id, user2.id)

      Fixtures.create_and_put_device_keys(user1, user1_device)

      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(user2.id, before_user1_change)

      {:ok, _} = Room.leave(room_id, user1.id)

      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(user2.id, before_user1_change)
    end

    test "includes users in :left when they leave the last shared room", %{
      room_id: room_id,
      creator: creator,
      user1: %{id: user1_id} = user1,
      user2: %{id: user2_id} = user2,
      user1_device: user1_device,
      user2_device: user2_device
    } do
      Fixtures.create_and_put_device_keys(user1, user1_device)
      Fixtures.create_and_put_device_keys(user2, user2_device)

      {:ok, _} = Room.join(room_id, user1.id)
      {:ok, event_id} = Room.join(room_id, user2.id)

      before_user1_leave = PaginationToken.new(room_id, event_id, :forward, System.os_time(:millisecond))

      {:ok, event_id} = Room.leave(room_id, user1.id)

      after_user1_leave = PaginationToken.new(room_id, event_id, :forward, System.os_time(:millisecond))

      expected = MapSet.new([user1_id])
      assert %{changed: @empty, left: ^expected} = KeyStore.all_changed_since(creator.id, before_user1_leave)
      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(creator.id, after_user1_leave)

      {:ok, event_id} = Room.leave(room_id, user2.id)

      after_user2_leave = PaginationToken.new(room_id, event_id, :forward, System.os_time(:millisecond))

      expected = MapSet.new([user1_id, user2_id])
      assert %{changed: @empty, left: ^expected} = KeyStore.all_changed_since(creator.id, before_user1_leave)
      expected = MapSet.new([user2_id])
      assert %{changed: @empty, left: ^expected} = KeyStore.all_changed_since(creator.id, after_user1_leave)
      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(creator.id, after_user2_leave)
    end

    test "does not include a user in :left if they still share other rooms", %{
      room_id: room_id,
      creator: creator,
      user1: %{id: user1_id} = user1,
      user2: %{id: user2_id} = user2,
      user1_device: user1_device,
      user2_device: user2_device
    } do
      Fixtures.create_and_put_device_keys(user1, user1_device)
      Fixtures.create_and_put_device_keys(user2, user2_device)

      {:ok, _} = Room.join(room_id, user1.id)
      {:ok, event_id} = Room.join(room_id, user2.id)

      {:ok, room_id2} = Room.create(creator)
      {:ok, _} = Room.invite(room_id2, creator.id, user1.id)
      {:ok, event_id2} = Room.join(room_id2, user1.id)

      before_leave =
        PaginationToken.new(%{room_id => event_id, room_id2 => event_id2}, :forward, System.os_time(:millisecond))

      {:ok, _} = Room.leave(room_id, user1.id)
      {:ok, event_id} = Room.leave(room_id, user2.id)

      after_leave =
        PaginationToken.new(%{room_id => event_id, room_id2 => event_id2}, :forward, System.os_time(:millisecond))

      expected = MapSet.new([user2_id])
      assert %{changed: @empty, left: ^expected} = KeyStore.all_changed_since(creator.id, before_leave)
      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(creator.id, after_leave)

      before_leave2 =
        PaginationToken.new(%{room_id => event_id, room_id2 => event_id2}, :forward, System.os_time(:millisecond))

      {:ok, _event_id} = Room.leave(room_id2, user1.id)

      expected = MapSet.new([user1_id])
      assert %{changed: @empty, left: ^expected} = KeyStore.all_changed_since(creator.id, before_leave2)
    end

    test "does not include a user in :changed if joined a room but previously shared another room", %{
      room_id: room_id,
      creator: creator,
      user1: user1,
      user1_device: user1_device
    } do
      Fixtures.create_and_put_device_keys(user1, user1_device)

      {:ok, room_id2} = Room.create(creator)
      {:ok, _} = Room.invite(room_id2, creator.id, user1.id)
      {:ok, _} = Room.join(room_id2, user1.id)

      before_user1_join = PaginationToken.new(%{}, :forward, System.os_time(:millisecond))

      {:ok, _} = Room.join(room_id, user1.id)

      after_user1_join = PaginationToken.new(%{}, :forward, System.os_time(:millisecond))

      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(creator.id, before_user1_join)
      assert %{changed: @empty, left: @empty} = KeyStore.all_changed_since(creator.id, after_user1_join)
    end
  end

  describe "query_all/2" do
    test "returns all cross-signing and device identity keys if the user is querying their own keys" do
      %{id: user_id} = user = Fixtures.user()
      {cross_signing_keys, _privkeys} = Fixtures.create_cross_signing_keys(user.id)
      {:ok, _keys} = User.CrossSigningKeyRing.put(user.id, cross_signing_keys)

      assert %{} = query_result = KeyStore.query_all(%{user.id => []}, user.id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["user_signing"]}} = query_result["user_signing_keys"]

      {user, %{id: device_id} = device} = Fixtures.device(user)
      {device_key, _signingkey} = Fixtures.device_keys(device.id, user.id)
      {:ok, _otk_counts} = User.put_device_keys(user.id, device.id, identity_keys: device_key)
      assert %{} = query_result = KeyStore.query_all(%{user.id => []}, user.id)

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
      {:ok, _user} = User.CrossSigningKeyRing.put(user.id, cross_signing_keys)

      assert %{} = query_result = KeyStore.query_all(%{user.id => []}, querying.id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      refute is_map_key(query_result, "user_signing_keys")

      {user, %{id: device_id} = device} = Fixtures.device(user)
      {device_key, _signingkey} = Fixtures.device_keys(device.id, user.id)
      {:ok, _otk_counts} = User.put_device_keys(user.id, device.id, identity_keys: device_key)
      assert %{} = query_result = KeyStore.query_all(%{user.id => []}, querying.id)

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
      {:ok, _otk_counts} = User.put_device_keys(user.id, device1.id, identity_keys: device1_key)
      {:ok, _otk_counts} = User.put_device_keys(user.id, device2.id, identity_keys: device2_key)
      {:ok, _otk_counts} = User.put_device_keys(user.id, device3.id, identity_keys: device3_key)
      assert %{} = query_result = KeyStore.query_all(%{user.id => []}, querying.id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 3 = map_size(device_keys_map)

      assert %{} = query_result = KeyStore.query_all(%{user.id => [device_id1, device_id3]}, querying.id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 2 = map_size(device_keys_map)
      refute Enum.any?(device_keys_map, fn {device_id, _} -> device_id == device_id2 end)
    end
  end

  describe "put_signatures/3" do
    setup do
      user = Fixtures.user()
      {csks, privkeys} = Fixtures.create_cross_signing_keys(user.id)
      {:ok, keys} = User.CrossSigningKeyRing.put(user.id, csks)

      {user, device} = Fixtures.device(user)
      {device_key, device_signingkey} = Fixtures.device_keys(device.id, user.id)
      {:ok, _otk_counts} = User.put_device_keys(user.id, device.id, identity_keys: device_key)
      {:ok, device} = Database.fetch_user_device(user.id, device.id)

      %{user: user, keys: keys, device: device, user_priv_csks: privkeys, device_signingkey: device_signingkey}
    end

    test "puts signatures for the user's MSK made by the user's devices", %{
      user: user,
      keys: keys,
      device: device,
      device_signingkey: device_signingkey
    } do
      master_key = CrossSigningKey.to_map(keys.cross_signing_key_ring.master, user.id)
      master_pubkeyb64 = master_key["keys"] |> Map.values() |> hd()

      {:ok, master_key} = Polyjuice.Util.JSON.sign(master_key, user.id, device_signingkey)

      assert :ok = KeyStore.put_signatures(user.id, device.id, %{user.id => %{master_pubkeyb64 => master_key}})
    end

    test "puts signatures for the user's own device keys", %{
      user: user,
      device: device,
      keys: keys,
      user_priv_csks: privkeys
    } do
      self_key = CrossSigningKey.to_map(keys.cross_signing_key_ring.self, user.id)
      self_pubkeyb64 = self_key["keys"] |> Map.values() |> hd()

      self_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.self_key, padding: false), self_pubkeyb64)

      {:ok, device_key} = Polyjuice.Util.JSON.sign(device.identity_keys, user.id, self_signingkey)

      assert :ok = KeyStore.put_signatures(user.id, device.id, %{user.id => %{device.id => device_key}})
    end

    test "puts signatures for another user's master CSK", %{
      user: user,
      keys: keys,
      device: device,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.user()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.id)
      {:ok, _glerp_keys} = User.CrossSigningKeyRing.put(glerp.id, glerp_csks)

      user_key = CrossSigningKey.to_map(keys.cross_signing_key_ring.user, user.id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_master_key = Keyword.fetch!(glerp_csks, :master_key)
      glerp_master_pubkeyb64 = glerp_master_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_master_key} = Polyjuice.Util.JSON.sign(glerp_master_key, user.id, user_signingkey)

      assert :ok =
               KeyStore.put_signatures(user.id, device.id, %{glerp.id => %{glerp_master_pubkeyb64 => glerp_master_key}})
    end

    test "errors with user_ids_do_not_match if CSKs do not belong to the given user" do
      user = Fixtures.user()
      {csks, _privkeys} = Fixtures.create_cross_signing_keys(user.id)

      glerp = Fixtures.user()
      assert {:error, :user_ids_do_not_match} = User.CrossSigningKeyRing.put(glerp.id, csks)
    end

    test "errors with invalid_signature if the signature is bad (device key -> master key)", %{
      user: user,
      keys: keys,
      device: device
    } do
      {_random, random_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      device_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(random_privkey, padding: false), device.id)

      master_key = CrossSigningKey.to_map(keys.cross_signing_key_ring.master, user.id)
      master_pubkeyb64 = master_key["keys"] |> Map.values() |> hd()

      {:ok, master_key} = Polyjuice.Util.JSON.sign(master_key, user.id, device_signingkey)

      assert {:error, failures} =
               KeyStore.put_signatures(user.id, device.id, %{user.id => %{master_pubkeyb64 => master_key}})

      assert 1 = map_size(failures)
      assert failures[user.id][master_pubkeyb64] == :invalid_signature
    end

    test "errors with invalid_signature if the signature is bad (self-signing key -> device key)", %{
      user: user,
      keys: keys,
      device: device
    } do
      self_key = CrossSigningKey.to_map(keys.cross_signing_key_ring.self, user.id)
      self_pubkeyb64 = self_key["keys"] |> Map.values() |> hd()

      {_random, random_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      self_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(random_privkey, padding: false), self_pubkeyb64)

      {:ok, device_key} = Polyjuice.Util.JSON.sign(device.identity_keys, user.id, self_signingkey)

      assert {:error, failures} = KeyStore.put_signatures(user.id, device.id, %{user.id => %{device.id => device_key}})
      assert 1 = map_size(failures)
      assert failures[user.id][device.id] == :invalid_signature
    end

    test "errors with :signature_key_not_known when a user tries to put a signature on another user's non-MSK key", %{
      user: user,
      keys: keys,
      device: device,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.user()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.id)
      {:ok, _glerp_keys} = User.CrossSigningKeyRing.put(glerp.id, glerp_csks)

      user_key = CrossSigningKey.to_map(keys.cross_signing_key_ring.user, user.id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_self_key = Keyword.fetch!(glerp_csks, :self_signing_key)
      glerp_self_pubkeyb64 = glerp_self_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_self_key} = Polyjuice.Util.JSON.sign(glerp_self_key, user.id, user_signingkey)

      assert {:error, failures} =
               KeyStore.put_signatures(user.id, device.id, %{glerp.id => %{glerp_self_pubkeyb64 => glerp_self_key}})

      assert 1 = map_size(failures)
      assert failures[glerp.id][glerp_self_pubkeyb64] == :signature_key_not_known
    end

    test "errors with :signature_key_not_known if the user does not have a MSK", %{
      user: user,
      keys: keys,
      device: device,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.user()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.id)

      user_key = CrossSigningKey.to_map(keys.cross_signing_key_ring.user, user.id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_master_key = Keyword.fetch!(glerp_csks, :master_key)
      glerp_master_pubkeyb64 = glerp_master_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_master_key} = Polyjuice.Util.JSON.sign(glerp_master_key, user.id, user_signingkey)

      assert {:error, failures} =
               KeyStore.put_signatures(user.id, device.id, %{glerp.id => %{glerp_master_pubkeyb64 => glerp_master_key}})

      assert 1 = map_size(failures)
      assert failures[glerp.id][glerp_master_pubkeyb64] == :signature_key_not_known
    end

    test "errors with :user_not_found when the user does not exist", %{user: user, device: device} do
      assert {:error, failures} =
               KeyStore.put_signatures(user.id, device.id, %{"@whateverman:localhost" => %{"asdf" => %{}}})

      assert 1 = map_size(failures)
      assert failures["@whateverman:localhost"]["asdf"] == :user_not_found
    end

    test "errors with :different_keys if the key included with the new signatures does not match the current key", %{
      user: user,
      keys: keys,
      device: device,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.user()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.id)
      # persist with a different `usage` value
      new_glerp_csks = put_in(glerp_csks[:master_key]["usage"], ["master", "something else"])
      {:ok, _glerp_keys} = User.CrossSigningKeyRing.put(glerp.id, new_glerp_csks)

      user_key = CrossSigningKey.to_map(keys.cross_signing_key_ring.user, user.id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_master_key = Keyword.fetch!(glerp_csks, :master_key)
      glerp_master_pubkeyb64 = glerp_master_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_master_key} = Polyjuice.Util.JSON.sign(glerp_master_key, user.id, user_signingkey)

      assert {:error, failures} =
               KeyStore.put_signatures(user.id, device.id, %{glerp.id => %{glerp_master_pubkeyb64 => glerp_master_key}})

      assert 1 = map_size(failures)
      assert failures[glerp.id][glerp_master_pubkeyb64] == :different_keys
    end
  end
end
