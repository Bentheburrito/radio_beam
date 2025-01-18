defmodule RadioBeam.User.KeysTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Device
  alias RadioBeam.User
  alias RadioBeam.User.Keys

  describe "query_all/2" do
    test "returns all cross-signing and device identity keys if the user is querying their own keys" do
      %{id: user_id} = user = Fixtures.user()
      cross_signing_keys = Fixtures.create_cross_signing_keys(user.id)
      {:ok, user} = User.CrossSigningKeyRing.put(user.id, cross_signing_keys)

      assert %{} = query_result = Keys.query_all(%{user.id => []}, user.id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["user_signing"]}} = query_result["user_signing_keys"]

      %{id: device_id} = device = Fixtures.device(user.id)
      {:ok, _device} = Device.put_keys(user.id, device.id, identity_keys: Fixtures.device_keys(device.id, user.id))
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
      cross_signing_keys = Fixtures.create_cross_signing_keys(user.id)
      {:ok, user} = User.CrossSigningKeyRing.put(user.id, cross_signing_keys)

      assert %{} = query_result = Keys.query_all(%{user.id => []}, querying.id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      refute is_map_key(query_result, "user_signing_keys")

      %{id: device_id} = device = Fixtures.device(user.id)
      {:ok, _device} = Device.put_keys(user.id, device.id, identity_keys: Fixtures.device_keys(device.id, user.id))
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
      %{id: device_id1} = device1 = Fixtures.device(user.id)
      %{id: device_id2} = device2 = Fixtures.device(user.id)
      %{id: device_id3} = device3 = Fixtures.device(user.id)

      {:ok, _device} = Device.put_keys(user.id, device1.id, identity_keys: Fixtures.device_keys(device1.id, user.id))
      {:ok, _device} = Device.put_keys(user.id, device2.id, identity_keys: Fixtures.device_keys(device2.id, user.id))
      {:ok, _device} = Device.put_keys(user.id, device3.id, identity_keys: Fixtures.device_keys(device3.id, user.id))
      assert %{} = query_result = Keys.query_all(%{user.id => []}, querying.id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 3 = map_size(device_keys_map)

      assert %{} = query_result = Keys.query_all(%{user.id => [device_id1, device_id3]}, querying.id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 2 = map_size(device_keys_map)
      refute Enum.any?(device_keys_map, fn {device_id, _} -> device_id == device_id2 end)
    end
  end
end
