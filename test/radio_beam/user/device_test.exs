defmodule RadioBeam.User.DeviceTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.Device

  describe "get/2" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "returns a user's device", %{user: user, device: %{id: device_id} = device} do
      assert {:ok, %Device{id: ^device_id}} = Device.get(user, device.id)
    end

    test "returns an error if not device is found for a valid user", %{user: user} do
      assert {:error, :not_found} = Device.get(user, "does not exist")
    end
  end

  describe "get_all/2" do
    setup do
      user = Fixtures.user()
      {user, device} = Fixtures.device(user)
      {user, device} = Fixtures.device(user)

      %{user: user, user_no_devices: Fixtures.user()}
    end

    test "gets all of a user's devices", %{user: user, user_no_devices: user2} do
      assert devices = Device.get_all(user)
      assert 2 = length(devices)
      assert [] = Device.get_all(user2)
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
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "adds the given one-time keys to a device", %{user: user, device: device} do
      {:ok, user} = Device.Keys.put(user, device.id, one_time_keys: @otk_keys)
      {:ok, device} = Device.get(user, device.id)

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
      {:ok, user} = Device.Keys.put(user, device.id, fallback_keys: @fallback_key)
      {:ok, device} = Device.get(user, device.id)

      assert {:ok, {%{"key" => "fallback1"}, _}} =
               Device.OneTimeKeyRing.claim_otk(device.one_time_key_ring, "signed_curve25519")
    end

    test "adds the given device identity keys to a device", %{user: user, device: device} do
      {device_key, _signingkey} = Fixtures.device_keys(device.id, user.id)

      {:ok, user} =
        Device.Keys.put(user, device.id, identity_keys: device_key)

      {:ok, device} = Device.get(user, device.id)

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

        assert {:error, :invalid_user_or_device_id} =
                 Device.Keys.put(user, device.id, identity_keys: device_key)
      end
    end
  end
end
