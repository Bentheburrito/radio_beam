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
      {:ok, device} =
        Device.put_keys(device.user_id, device.id, identity_keys: Fixtures.device_keys(device.id, device.user_id))

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
                 Device.put_keys(device.user_id, device.id, identity_keys: Fixtures.device_keys(device_id, user_id))
      end
    end
  end
end
