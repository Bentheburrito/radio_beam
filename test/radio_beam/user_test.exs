defmodule RadioBeam.UserTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.Database
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
  describe "put_device_keys/3" do
    setup do
      account = Fixtures.create_account()
      device = Fixtures.create_device(account.user_id)
      %{account: account, device: device}
    end

    test "adds the given one-time keys to a device", %{account: account, device: device} do
      {:ok, _otk_counts} = User.put_device_keys(account.user_id, device.id, one_time_keys: @otk_keys)
      {:ok, device} = Database.fetch_user_device(account.user_id, device.id)

      assert %{"signed_curve25519" => 2} = User.Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring)
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
    test "adds the given fallback key to a device", %{account: account, device: device} do
      {:ok, _otk_counts} = User.put_device_keys(account.user_id, device.id, fallback_keys: @fallback_key)
      {:ok, device} = Database.fetch_user_device(account.user_id, device.id)

      assert {:ok, {"AAAAGj", %{"key" => "fallback1"}, _}} =
               Device.OneTimeKeyRing.claim_otk(device.one_time_key_ring, "signed_curve25519")
    end

    test "adds the given device identity keys to a device", %{account: account, device: device} do
      {device_key, _signingkey} = Fixtures.device_keys(device.id, account.user_id)

      {:ok, _otk_counts} = User.put_device_keys(account.user_id, device.id, identity_keys: device_key)
      {:ok, device} = Database.fetch_user_device(account.user_id, device.id)

      expected_ed_key = "ed25519:#{device.id}"
      expected_ed_value = device_key["keys"] |> Map.values() |> hd()

      assert %{"keys" => %{^expected_ed_key => ^expected_ed_value}} = device.identity_keys
    end

    test "errors when the user or device ID on the given device identity keys map don't match the device's ID or its owner's user ID",
         %{account: account, device: device} do
      for device_id <- ["blah", device.id],
          user_id <- ["blah", account.user_id],
          device_id != device.id or user_id != account.user_id do
        {device_key, _signingkey} = Fixtures.device_keys(device_id, user_id)

        assert {:error, :invalid_user_or_device_id} =
                 User.put_device_keys(account.user_id, device.id, identity_keys: device_key)
      end
    end
  end

  describe "put_account_data/4" do
    setup do
      %{account: Fixtures.create_account()}
    end

    test "successfully puts global account data", %{account: account} do
      assert :ok = User.put_account_data(account.user_id, :global, "m.some_config", %{"key" => "value"})

      assert {:ok, %{global: %{"m.some_config" => %{"key" => "value"}}}} = User.get_account_data(account.user_id)
    end

    test "successfully puts room account data", %{account: account} do
      {:ok, room_id} = Room.create(account.user_id)

      assert :ok = User.put_account_data(account.user_id, room_id, "m.some_config", %{"other" => "value"})
    end

    test "cannot put m.fully_read or m.push_rules for any scope", %{account: account} do
      assert {:error, :invalid_type} =
               User.put_account_data(account.user_id, :global, "m.fully_read", %{"key" => "value"})

      assert {:error, :invalid_type} =
               User.put_account_data(account.user_id, :global, "m.push_rules", %{"key" => "value"})

      {:ok, room_id} = Room.create(account.user_id)

      assert {:error, :invalid_type} =
               User.put_account_data(account.user_id, room_id, "m.fully_read", %{"other" => "value"})

      assert {:error, :invalid_type} =
               User.put_account_data(account.user_id, room_id, "m.push_rules", %{"other" => "value"})
    end

    test "cannot put room account data under a room that doesn't exist", %{account: account} do
      assert {:error, :invalid_room_id} =
               User.put_account_data(account.user_id, "!huh@localhost", "m.some_config", %{"other" => "value"})
    end

    test "cannot put any account data for an unknown user", %{account: account} do
      assert {:error, :not_found} =
               User.put_account_data("@hellooo:localhost", :global, "m.some_config", %{"key" => "value"})

      {:ok, room_id} = Room.create(account.user_id)

      assert {:error, :not_found} =
               User.put_account_data("@hellooo:localhost", room_id, "m.some_config", %{"other" => "value"})
    end
  end
end
