defmodule RadioBeam.User.DeviceTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.Device

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
      {:ok, device} = Device.put_keys(device, user.id, one_time_keys: @otk_keys)

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
      {:ok, device} = Device.put_keys(device, user.id, fallback_keys: @fallback_key)

      assert {:ok, {"AAAAGj", %{"key" => "fallback1"}, _}} =
               Device.OneTimeKeyRing.claim_otk(device.one_time_key_ring, "signed_curve25519")
    end

    test "adds the given device identity keys to a device", %{user: user, device: device} do
      {device_key, _signingkey} = Fixtures.device_keys(device.id, user.id)

      {:ok, device} = Device.put_keys(device, user.id, identity_keys: device_key)

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
                 Device.put_keys(device, user.id, identity_keys: device_key)
      end
    end
  end
end
