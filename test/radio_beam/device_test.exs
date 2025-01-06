defmodule RadioBeam.DeviceTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Device

  describe "get/2" do
    setup do
      user = Fixtures.user()
      %{user: user, device: Fixtures.device(user.id)}
    end

    test "returns a user's device", %{user: user, device: device} do
      user_id = user.id
      assert {:ok, %Device{user_id: ^user_id}} = Device.get(user.id, device.id)
    end

    test "returns an error if not device is found for a valid user", %{user: user} do
      assert {:error, :not_found} = Device.get(user.id, "does not exist")
    end
  end

  describe "get_all_by_user/2" do
    setup do
      user = Fixtures.user()
      Fixtures.device(user.id)
      Fixtures.device(user.id)

      %{user: user, user_no_devices: Fixtures.user()}
    end

    test "gets all of a user's devices", %{user: user, user_no_devices: user2} do
      assert {:ok, devices} = Device.get_all_by_user(user.id)
      assert 2 = length(devices)
      assert {:ok, []} = Device.get_all_by_user(user2.id)
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
  describe "put_keys/3" do
    setup do
      user = Fixtures.user()
      %{user: user, device: Fixtures.device(user.id)}
    end

    test "adds the given one-time keys to a device", %{device: device} do
      {:ok, device} = Device.put_keys(device.user_id, device.id, one_time_keys: @otk_keys)

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
    test "adds the given fallback key to a device", %{device: device} do
      {:ok, device} = Device.put_keys(device.user_id, device.id, fallback_keys: @fallback_key)

      assert {:ok, {%{"key" => "fallback1"}, _}} =
               Device.OneTimeKeyRing.claim_otk(device.one_time_key_ring, "signed_curve25519")
    end

    test "adds the given device identity keys to a device", %{device: device} do
      {:ok, device} = Device.put_keys(device.user_id, device.id, identity_keys: device_keys(device.id, device.user_id))

      expected_curve_key = "curve25519:#{device.id}"
      expected_ed_key = "ed25519:#{device.id}"

      assert %{"keys" => %{^expected_curve_key => "curve_key", ^expected_ed_key => "ed_key"}} = device.identity_keys
    end

    test "errors when the user or device ID on the given device identity keys map don't match the device's ID or its owner's user ID",
         %{device: device} do
      for device_id <- ["blah", device.id],
          user_id <- ["blah", device.user_id],
          device_id != device.id or user_id != device.user_id do
        assert {:error, :invalid_user_or_device_id} =
                 Device.put_keys(device.user_id, device.id, identity_keys: device_keys(device_id, user_id))
      end
    end

    test "adds the given master_key to the device", %{device: device} do
      {:ok, device} =
        Device.put_keys(device.user_id, device.id,
          master_key: %{
            "keys" => %{"ed25519:base64+master+public+key" => "base64+master+public+key"},
            "usage" => ["master"],
            "user_id" => device.user_id
          }
        )

      assert Base.decode64!("base64+master+public+key") == device.master_key.key
      assert "ed25519" = device.master_key.algorithm
    end

    test "errors if the user ID on the key doesn't match the device's owner", %{device: device} do
      assert {:error, :user_ids_do_not_match} =
               Device.put_keys(device.user_id, device.id,
                 master_key: %{
                   "keys" => %{"ed25519:base64+master+public+key" => "base64+master+public+key"},
                   "usage" => ["master"],
                   "user_id" => "@alice:example.com"
                 }
               )
    end

    test "adds all the given cross-signing keys to the device, as long as the user/self keys were signed by the master key",
         %{device: device} do
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

      {:ok, device} =
        Device.put_keys(device.user_id, device.id,
          master_key: master_key,
          self_signing_key: self_signing_key,
          user_signing_key: user_signing_key
        )

      assert ^master_pubkey = device.master_key.key
      assert "ed25519" = device.master_key.algorithm
    end

    test "errors with :missing_master_key when trying to put a self-/user-signing key without previously supplying a master key",
         %{device: device} do
      master_key_id = "base64masterpublickey"
      {_master_pubkey, master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

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

      {:error, :missing_master_key} = Device.put_keys(device.user_id, device.id, self_signing_key: self_signing_key)
      {:error, :missing_master_key} = Device.put_keys(device.user_id, device.id, user_signing_key: user_signing_key)
    end

    test "errors with :missing_or_invalid_master_key_signatures when a signature is missing on the self/user keys",
         %{device: device} do
      master_key_id = "base64masterpublickey"
      {master_pubkey, _master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      master_key = %{
        "keys" => %{("ed25519:" <> master_key_id) => Base.encode64(master_pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => device.user_id
      }

      self_signing_key =
        %{
          "keys" => %{
            "ed25519:base64selfsigningpublickey" =>
              Base.encode64("base64+self+signing+master+public+key", padding: false)
          },
          "usage" => ["self_signing"],
          "user_id" => device.user_id
        }

      user_signing_key =
        %{
          "keys" => %{
            "ed25519:base64usersigningpublickey" =>
              Base.encode64("base64+user+signing+master+public+key", padding: false)
          },
          "usage" => ["user_signing"],
          "user_id" => device.user_id
        }

      {:error, :missing_or_invalid_master_key_signatures} =
        Device.put_keys(device.user_id, device.id,
          master_key: master_key,
          self_signing_key: self_signing_key
        )

      {:error, :missing_or_invalid_master_key_signatures} =
        Device.put_keys(device.user_id, device.id,
          master_key: master_key,
          user_signing_key: user_signing_key
        )
    end

    test "errors with :missing_or_invalid_master_key_signatures when a bad signature is on the self/user keys",
         %{device: device} do
      master_key_id = "base64masterpublickey"
      {_master_pubkey, master_privkey} = :crypto.generate_key(:eddsa, :ed25519)
      {master_pubkey, _master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

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

      {:error, :missing_or_invalid_master_key_signatures} =
        Device.put_keys(device.user_id, device.id,
          master_key: master_key,
          self_signing_key: self_signing_key
        )

      {:error, :missing_or_invalid_master_key_signatures} =
        Device.put_keys(device.user_id, device.id,
          master_key: master_key,
          user_signing_key: user_signing_key
        )
    end
  end

  defp device_keys(id, user_id) do
    %{
      "algorithms" => [
        "m.olm.v1.curve25519-aes-sha2",
        "m.megolm.v1.aes-sha2"
      ],
      "device_id" => id,
      "keys" => %{
        "curve25519:#{id}" => "curve_key",
        "ed25519:#{id}" => "ed_key"
      },
      "signatures" => %{
        user_id => %{
          "ed25519:#{id}" => "dSO80A01XiigH3uBiDVx/EjzaoycHcjq9lfQX0uWsqxl2giMIiSPR8a4d291W1ihKJL/a+myXS367WT6NAIcBA"
        }
      },
      "user_id" => user_id
    }
  end
end
