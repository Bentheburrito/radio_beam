defmodule RadioBeam.User.KeyStoreTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.CrossSigningKey
  alias RadioBeam.User.Database
  alias RadioBeam.User.Device
  alias RadioBeam.User.KeyStore

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
      %{user_id: user_id} = account = Fixtures.create_account()
      device = Fixtures.create_device(user_id)
      device_id = device.id

      algo = "signed_curve25519"

      assert map_size(Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring)) == 0

      {:ok, _otk_counts} =
        User.put_device_keys(account.user_id, device.id, one_time_keys: @otk_keys, fallback_keys: @fallback_key)

      {:ok, device} = Database.fetch_user_device(account.user_id, device.id)

      assert %{^algo => 2} = Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring)

      task = Task.async(fn -> KeyStore.claim_otks(%{account.user_id => %{device.id => algo}}) end)

      assert %{^user_id => %{^device_id => key_id_to_key_obj1}} =
               KeyStore.claim_otks(%{account.user_id => %{device.id => algo}})

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

  describe "all_changed_since/3" do
    setup do
      creator = Fixtures.create_account()
      account1 = Fixtures.create_account()
      account2 = Fixtures.create_account()

      account1_device = Fixtures.create_device(account1.user_id)
      account2_device = Fixtures.create_device(account2.user_id)

      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _} = Room.invite(room_id, creator.user_id, account1.user_id)
      {:ok, last_event_id} = Room.invite(room_id, creator.user_id, account2.user_id)

      %{
        room_id: room_id,
        last_event_id: last_event_id,
        creator: creator,
        account1: account1,
        account2: account2,
        account1_device: account1_device,
        account2_device: account2_device
      }
    end

    defp always_not_found(_room_id), do: {:error, :not_found}

    defp fetcher(fetch_map) do
      fn room_id -> with :error <- Map.fetch(fetch_map, room_id), do: {:error, :not_found} end
    end

    @empty MapSet.new()
    test "returns an empty changed/left lists if the user is in no/empty rooms" do
      account = Fixtures.create_account()
      since_now = System.os_time(:millisecond)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(account.user_id, &always_not_found/1, since_now)

      {:ok, room_id} = Room.create(account.user_id)
      :pong = Room.Server.ping(room_id)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(account.user_id, &always_not_found/1, since_now)
    end

    test "does not include user's own key updates in changed" do
      before_update = System.os_time(:millisecond)

      account = Fixtures.create_account()
      device = Fixtures.create_device(account.user_id)
      {:ok, _room_id} = Room.create(account.user_id)

      _device = Fixtures.create_and_put_device_keys(account.user_id, device.id)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(account.user_id, &always_not_found/1, before_update)
    end

    test "returns changed users who have added device identity keys since the given timestamp", %{
      room_id: room_id,
      creator: creator,
      account1: %{user_id: account1_id} = account1,
      account2: %{user_id: account2_id} = account2,
      account1_device: account1_device,
      account2_device: account2_device
    } do
      {:ok, _} = Room.join(room_id, account1.user_id)
      {:ok, event_id} = Room.join(room_id, account2.user_id)

      Process.sleep(1)

      before_account1_change = System.os_time(:millisecond)
      fetcher = fetcher(%{room_id => event_id})

      Process.sleep(1)

      Fixtures.create_and_put_device_keys(account1.user_id, account1_device.id)

      Process.sleep(1)

      after_account1_change = System.os_time(:millisecond)

      Process.sleep(1)

      expected = MapSet.new([account1_id])

      assert %{changed: ^expected, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, fetcher, before_account1_change)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, fetcher, after_account1_change)

      Process.sleep(1)

      Fixtures.create_and_put_device_keys(account2.user_id, account2_device.id)
      after_account2_change = System.os_time(:millisecond)

      expected = MapSet.new([account1_id, account2_id])

      assert %{changed: ^expected, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, fetcher, before_account1_change)

      expected = MapSet.new([account2_id])

      assert %{changed: ^expected, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, fetcher, after_account1_change)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, fetcher, after_account2_change)
    end

    test "returns changed users who have joined the room since the given timestamp", %{
      room_id: room_id,
      last_event_id: last_event_id,
      creator: creator,
      account1: %{user_id: account1_id} = account1,
      account2: %{user_id: account2_id} = account2,
      account1_device: account1_device,
      account2_device: account2_device
    } do
      Fixtures.create_and_put_device_keys(account1.user_id, account1_device.id)
      Fixtures.create_and_put_device_keys(account2.user_id, account2_device.id)

      before_account1_join = System.os_time(:millisecond)
      before_account1_join_fetcher = fetcher(%{room_id => last_event_id})

      {:ok, event_id} = Room.join(room_id, account1.user_id)

      after_account1_join = System.os_time(:millisecond)
      after_account1_join_fetcher = fetcher(%{room_id => event_id})

      expected = MapSet.new([account1_id])

      assert %{changed: ^expected, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, before_account1_join_fetcher, before_account1_join)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, after_account1_join_fetcher, after_account1_join)

      {:ok, event_id} = Room.join(room_id, account2.user_id)

      after_account2_join = System.os_time(:millisecond)
      after_account2_join_fetcher = fetcher(%{room_id => event_id})

      expected = MapSet.new([account1_id, account2_id])

      assert %{changed: ^expected, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, before_account1_join_fetcher, before_account1_join)

      expected = MapSet.new([account2_id])

      assert %{changed: ^expected, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, after_account1_join_fetcher, after_account1_join)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, after_account2_join_fetcher, after_account2_join)
    end

    test "does not return users for which we do not share a room", %{
      room_id: room_id,
      last_event_id: last_event_id,
      account1: account1,
      account2: account2,
      account1_device: account1_device
    } do
      before_account1_change = System.os_time(:millisecond)
      before_account1_change_fetcher = fetcher(%{room_id => last_event_id})

      {:ok, _} = Room.join(room_id, account1.user_id)
      # account2 not joining!
      # {:ok, _} = Room.join(room_id, account2.user_id)

      Fixtures.create_and_put_device_keys(account1.user_id, account1_device.id)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(account2.user_id, before_account1_change_fetcher, before_account1_change)

      {:ok, _} = Room.leave(room_id, account1.user_id)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(account2.user_id, before_account1_change_fetcher, before_account1_change)
    end

    test "includes users in :left when they leave the last shared room", %{
      room_id: room_id,
      creator: creator,
      account1: %{user_id: account1_id} = account1,
      account2: %{user_id: account2_id} = account2,
      account1_device: account1_device,
      account2_device: account2_device
    } do
      Fixtures.create_and_put_device_keys(account1.user_id, account1_device.id)
      Fixtures.create_and_put_device_keys(account2.user_id, account2_device.id)

      {:ok, _} = Room.join(room_id, account1.user_id)
      {:ok, event_id} = Room.join(room_id, account2.user_id)

      before_account1_leave = System.os_time(:millisecond)
      before_account1_leave_fetcher = fetcher(%{room_id => event_id})

      {:ok, event_id} = Room.leave(room_id, account1.user_id)

      after_account1_leave = System.os_time(:millisecond)
      after_account1_leave_fetcher = fetcher(%{room_id => event_id})

      expected = MapSet.new([account1_id])

      assert %{changed: @empty, left: ^expected} =
               KeyStore.all_changed_since(creator.user_id, before_account1_leave_fetcher, before_account1_leave)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, after_account1_leave_fetcher, after_account1_leave)

      {:ok, event_id} = Room.leave(room_id, account2.user_id)

      after_account2_leave = System.os_time(:millisecond)
      after_account2_leave_fetcher = fetcher(%{room_id => event_id})

      expected = MapSet.new([account1_id, account2_id])

      assert %{changed: @empty, left: ^expected} =
               KeyStore.all_changed_since(creator.user_id, before_account1_leave_fetcher, before_account1_leave)

      expected = MapSet.new([account2_id])

      assert %{changed: @empty, left: ^expected} =
               KeyStore.all_changed_since(creator.user_id, after_account1_leave_fetcher, after_account1_leave)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, after_account2_leave_fetcher, after_account2_leave)
    end

    test "does not include a user in :left if they still share other rooms", %{
      room_id: room_id,
      creator: creator,
      account1: %{user_id: account1_id} = account1,
      account2: %{user_id: account2_id} = account2,
      account1_device: account1_device,
      account2_device: account2_device
    } do
      Fixtures.create_and_put_device_keys(account1.user_id, account1_device.id)
      Fixtures.create_and_put_device_keys(account2.user_id, account2_device.id)

      {:ok, _} = Room.join(room_id, account1.user_id)
      {:ok, event_id} = Room.join(room_id, account2.user_id)

      {:ok, room_id2} = Room.create(creator.user_id)
      {:ok, _} = Room.invite(room_id2, creator.user_id, account1.user_id)
      {:ok, event_id2} = Room.join(room_id2, account1.user_id)

      before_leave = System.os_time(:millisecond)
      before_leave_fetcher = fetcher(%{room_id => event_id, room_id2 => event_id2})

      {:ok, _} = Room.leave(room_id, account1.user_id)
      {:ok, event_id} = Room.leave(room_id, account2.user_id)

      after_leave = System.os_time(:millisecond)
      after_leave_fetcher = fetcher(%{room_id => event_id, room_id2 => event_id2})

      expected = MapSet.new([account2_id])

      assert %{changed: @empty, left: ^expected} =
               KeyStore.all_changed_since(creator.user_id, before_leave_fetcher, before_leave)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, after_leave_fetcher, after_leave)

      before_leave2 = System.os_time(:millisecond)
      before_leave2_fetcher = fetcher(%{room_id => event_id, room_id2 => event_id2})

      {:ok, _event_id} = Room.leave(room_id2, account1.user_id)

      expected = MapSet.new([account1_id])

      assert %{changed: @empty, left: ^expected} =
               KeyStore.all_changed_since(creator.user_id, before_leave2_fetcher, before_leave2)
    end

    test "does not include a user in :changed if joined a room but previously shared another room", %{
      room_id: room_id,
      creator: creator,
      account1: account1,
      account1_device: account1_device
    } do
      Fixtures.create_and_put_device_keys(account1.user_id, account1_device.id)

      {:ok, room_id2} = Room.create(creator.user_id)
      {:ok, _} = Room.invite(room_id2, creator.user_id, account1.user_id)
      {:ok, _} = Room.join(room_id2, account1.user_id)

      before_account1_join = System.os_time(:millisecond)

      {:ok, _} = Room.join(room_id, account1.user_id)

      after_account1_join = System.os_time(:millisecond)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, &always_not_found/1, before_account1_join)

      assert %{changed: @empty, left: @empty} =
               KeyStore.all_changed_since(creator.user_id, &always_not_found/1, after_account1_join)
    end
  end

  describe "query_all/2" do
    test "returns all cross-signing and device identity keys if the user is querying their own keys" do
      %{user_id: user_id} = account = Fixtures.create_account()
      {cross_signing_keys, _privkeys} = Fixtures.create_cross_signing_keys(account.user_id)
      {:ok, _key_ring} = KeyStore.put_cross_signing_keys(account.user_id, cross_signing_keys)

      assert %{} = query_result = KeyStore.query_all(%{account.user_id => []}, account.user_id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["user_signing"]}} = query_result["user_signing_keys"]

      %{id: device_id} = device = Fixtures.create_device(user_id)
      {device_key, _signingkey} = Fixtures.device_keys(device.id, account.user_id)
      {:ok, _otk_counts} = User.put_device_keys(account.user_id, device.id, identity_keys: device_key)
      assert %{} = query_result = KeyStore.query_all(%{account.user_id => []}, account.user_id)

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
      querying = Fixtures.create_account()
      %{user_id: user_id} = account = Fixtures.create_account()
      {cross_signing_keys, _privkeys} = Fixtures.create_cross_signing_keys(account.user_id)
      {:ok, _key_ring} = KeyStore.put_cross_signing_keys(account.user_id, cross_signing_keys)

      assert %{} = query_result = KeyStore.query_all(%{account.user_id => []}, querying.user_id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      refute is_map_key(query_result, "user_signing_keys")

      %{id: device_id} = device = Fixtures.create_device(account.user_id)
      {device_key, _signingkey} = Fixtures.device_keys(device.id, account.user_id)
      {:ok, _otk_counts} = User.put_device_keys(account.user_id, device.id, identity_keys: device_key)
      assert %{} = query_result = KeyStore.query_all(%{account.user_id => []}, querying.user_id)

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
      querying = Fixtures.create_account()

      %{user_id: user_id} = account = Fixtures.create_account()
      %{id: device_id1} = device1 = Fixtures.create_device(account.user_id)
      %{id: device_id2} = device2 = Fixtures.create_device(account.user_id)
      %{id: device_id3} = device3 = Fixtures.create_device(account.user_id)

      {device1_key, _signingkey} = Fixtures.device_keys(device1.id, account.user_id)
      {device2_key, _signingkey} = Fixtures.device_keys(device2.id, account.user_id)
      {device3_key, _signingkey} = Fixtures.device_keys(device3.id, account.user_id)
      {:ok, _otk_counts} = User.put_device_keys(account.user_id, device1.id, identity_keys: device1_key)
      {:ok, _otk_counts} = User.put_device_keys(account.user_id, device2.id, identity_keys: device2_key)
      {:ok, _otk_counts} = User.put_device_keys(account.user_id, device3.id, identity_keys: device3_key)
      assert %{} = query_result = KeyStore.query_all(%{account.user_id => []}, querying.user_id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 3 = map_size(device_keys_map)

      assert %{} = query_result = KeyStore.query_all(%{account.user_id => [device_id1, device_id3]}, querying.user_id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 2 = map_size(device_keys_map)
      refute Enum.any?(device_keys_map, fn {device_id, _} -> device_id == device_id2 end)
    end
  end

  describe "put_signatures/3" do
    setup do
      account = Fixtures.create_account()
      {csks, privkeys} = Fixtures.create_cross_signing_keys(account.user_id)
      {:ok, key_store} = KeyStore.put_cross_signing_keys(account.user_id, csks)

      device = Fixtures.create_device(account.user_id)
      {device_key, device_signingkey} = Fixtures.device_keys(device.id, account.user_id)
      {:ok, _otk_counts} = User.put_device_keys(account.user_id, device.id, identity_keys: device_key)
      {:ok, device} = Database.fetch_user_device(account.user_id, device.id)

      %{
        account: account,
        key_ring: key_store.cross_signing_key_ring,
        device: device,
        user_priv_csks: privkeys,
        device_signingkey: device_signingkey
      }
    end

    test "puts signatures for the user's MSK made by the user's devices", %{
      account: account,
      key_ring: key_ring,
      device: device,
      device_signingkey: device_signingkey
    } do
      master_key = CrossSigningKey.to_map(key_ring.master, account.user_id)
      master_pubkeyb64 = master_key["keys"] |> Map.values() |> hd()

      {:ok, master_key} = Polyjuice.Util.JSON.sign(master_key, account.user_id, device_signingkey)

      assert :ok =
               KeyStore.put_signatures(account.user_id, device.id, %{
                 account.user_id => %{master_pubkeyb64 => master_key}
               })
    end

    test "puts signatures for the user's own device keys", %{
      account: account,
      device: device,
      key_ring: key_ring,
      user_priv_csks: privkeys
    } do
      self_key = CrossSigningKey.to_map(key_ring.self, account.user_id)
      self_pubkeyb64 = self_key["keys"] |> Map.values() |> hd()

      self_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.self_key, padding: false), self_pubkeyb64)

      {:ok, device_key} = Polyjuice.Util.JSON.sign(device.identity_keys, account.user_id, self_signingkey)

      assert :ok = KeyStore.put_signatures(account.user_id, device.id, %{account.user_id => %{device.id => device_key}})
    end

    test "puts signatures for another user's master CSK", %{
      account: account,
      key_ring: key_ring,
      device: device,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.create_account()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.user_id)
      {:ok, _glerp_keys} = KeyStore.put_cross_signing_keys(glerp.user_id, glerp_csks)

      user_key = CrossSigningKey.to_map(key_ring.user, account.user_id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_master_key = Keyword.fetch!(glerp_csks, :master_key)
      glerp_master_pubkeyb64 = glerp_master_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_master_key} = Polyjuice.Util.JSON.sign(glerp_master_key, account.user_id, user_signingkey)

      assert :ok =
               KeyStore.put_signatures(account.user_id, device.id, %{
                 glerp.user_id => %{glerp_master_pubkeyb64 => glerp_master_key}
               })
    end

    test "errors with user_ids_do_not_match if CSKs do not belong to the given user" do
      account = Fixtures.create_account()
      {csks, _privkeys} = Fixtures.create_cross_signing_keys(account.user_id)

      glerp = Fixtures.create_account()
      assert {:error, :user_ids_do_not_match} = KeyStore.put_cross_signing_keys(glerp.user_id, csks)
    end

    test "errors with invalid_signature if the signature is bad (device key -> master key)", %{
      account: account,
      key_ring: key_ring,
      device: device
    } do
      {_random, random_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      device_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(random_privkey, padding: false), device.id)

      master_key = CrossSigningKey.to_map(key_ring.master, account.user_id)
      master_pubkeyb64 = master_key["keys"] |> Map.values() |> hd()

      {:ok, master_key} = Polyjuice.Util.JSON.sign(master_key, account.user_id, device_signingkey)

      assert {:error, failures} =
               KeyStore.put_signatures(account.user_id, device.id, %{
                 account.user_id => %{master_pubkeyb64 => master_key}
               })

      assert 1 = map_size(failures)
      assert failures[account.user_id][master_pubkeyb64] == :invalid_signature
    end

    test "errors with invalid_signature if the signature is bad (self-signing key -> device key)", %{
      account: account,
      key_ring: key_ring,
      device: device
    } do
      self_key = CrossSigningKey.to_map(key_ring.self, account.user_id)
      self_pubkeyb64 = self_key["keys"] |> Map.values() |> hd()

      {_random, random_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      self_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(random_privkey, padding: false), self_pubkeyb64)

      {:ok, device_key} = Polyjuice.Util.JSON.sign(device.identity_keys, account.user_id, self_signingkey)

      assert {:error, failures} =
               KeyStore.put_signatures(account.user_id, device.id, %{account.user_id => %{device.id => device_key}})

      assert 1 = map_size(failures)
      assert failures[account.user_id][device.id] == :invalid_signature
    end

    test "errors with :signature_key_not_known when a user tries to put a signature on another user's non-MSK key", %{
      account: account,
      key_ring: key_ring,
      device: device,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.create_account()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.user_id)
      {:ok, _glerp_key_store} = KeyStore.put_cross_signing_keys(glerp.user_id, glerp_csks)

      user_key = CrossSigningKey.to_map(key_ring.user, account.user_id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_self_key = Keyword.fetch!(glerp_csks, :self_signing_key)
      glerp_self_pubkeyb64 = glerp_self_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_self_key} = Polyjuice.Util.JSON.sign(glerp_self_key, account.user_id, user_signingkey)

      assert {:error, failures} =
               KeyStore.put_signatures(account.user_id, device.id, %{
                 glerp.user_id => %{glerp_self_pubkeyb64 => glerp_self_key}
               })

      assert 1 = map_size(failures)
      assert failures[glerp.user_id][glerp_self_pubkeyb64] == :signature_key_not_known
    end

    test "errors with :signature_key_not_known if the user does not have a MSK", %{
      account: account,
      key_ring: key_ring,
      device: device,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.create_account()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.user_id)

      user_key = CrossSigningKey.to_map(key_ring.user, account.user_id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_master_key = Keyword.fetch!(glerp_csks, :master_key)
      glerp_master_pubkeyb64 = glerp_master_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_master_key} = Polyjuice.Util.JSON.sign(glerp_master_key, account.user_id, user_signingkey)

      assert {:error, failures} =
               KeyStore.put_signatures(account.user_id, device.id, %{
                 glerp.user_id => %{glerp_master_pubkeyb64 => glerp_master_key}
               })

      assert 1 = map_size(failures)
      assert failures[glerp.user_id][glerp_master_pubkeyb64] == :signature_key_not_known
    end

    test "errors with :user_not_found when the user does not exist", %{account: account, device: device} do
      assert {:error, failures} =
               KeyStore.put_signatures(account.user_id, device.id, %{"@whateverman:localhost" => %{"asdf" => %{}}})

      assert 1 = map_size(failures)
      assert failures["@whateverman:localhost"]["asdf"] == :user_not_found
    end

    test "errors with :different_keys if the key included with the new signatures does not match the current key", %{
      account: account,
      key_ring: key_ring,
      device: device,
      user_priv_csks: privkeys
    } do
      glerp = Fixtures.create_account()
      {glerp_csks, _privkeys} = Fixtures.create_cross_signing_keys(glerp.user_id)
      # persist with a different `usage` value
      new_glerp_csks = put_in(glerp_csks[:master_key]["usage"], ["master", "something else"])
      {:ok, _glerp_keys} = KeyStore.put_cross_signing_keys(glerp.user_id, new_glerp_csks)

      user_key = CrossSigningKey.to_map(key_ring.user, account.user_id)
      user_pubkeyb64 = user_key["keys"] |> Map.values() |> hd()

      glerp_master_key = Keyword.fetch!(glerp_csks, :master_key)
      glerp_master_pubkeyb64 = glerp_master_key["keys"] |> Map.values() |> hd()

      user_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkeys.user_key, padding: false), user_pubkeyb64)

      {:ok, glerp_master_key} = Polyjuice.Util.JSON.sign(glerp_master_key, account.user_id, user_signingkey)

      assert {:error, failures} =
               KeyStore.put_signatures(account.user_id, device.id, %{
                 glerp.user_id => %{glerp_master_pubkeyb64 => glerp_master_key}
               })

      assert 1 = map_size(failures)
      assert failures[glerp.user_id][glerp_master_pubkeyb64] == :different_keys
    end
  end
end
