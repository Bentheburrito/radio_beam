defmodule RadioBeam.UserTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Device
  alias RadioBeam.Room
  alias RadioBeam.User

  describe "new/1" do
    @password "Ar3allyg00dpwd!@#$"
    test "can create a new user from params with a valid user ID" do
      valid_ids = [
        "@hello:world",
        "@greetings_sir123:inter.net",
        "@_xcoolguy9x_:servername",
        "@+=-_/somehowvalid:ok.com",
        "@snowful:matrix.org"
      ]

      for id <- valid_ids, do: assert({:ok, %User{id: ^id}} = User.new(id, @password))
    end

    test "will not create users with invalid user IDs" do
      invalid_ids = [
        "hello:world",
        "@:servername",
        "@Hello:world",
        "@hi!there:inter.net",
        "@hello :world",
        super_long_user_id()
      ]

      for id <- invalid_ids, do: assert({:error, _} = User.new(id, @password))
    end
  end

  describe "put_new/1" do
    test "successfully puts a new user" do
      {:ok, user} = User.new("@danflashestshirts:localhost", "Test!234")
      assert :ok = User.put_new(user)
    end

    test "errors if a user with the same ID already exists" do
      user = Fixtures.user()
      assert {:error, :already_exists} = User.put_new(user)
    end
  end

  describe "put_account_data" do
    setup do
      %{user: Fixtures.user()}
    end

    test "successfully puts global account data", %{user: user} do
      assert :ok = User.put_account_data(user.id, :global, "m.some_config", %{"key" => "value"})
      assert {:ok, %User{account_data: %{global: %{"m.some_config" => %{"key" => "value"}}}}} = User.get(user.id)
    end

    test "successfully puts room account data", %{user: user} do
      {:ok, room_id} = Room.create(user)
      assert :ok = User.put_account_data(user.id, room_id, "m.some_config", %{"other" => "value"})
      assert {:ok, %User{account_data: %{^room_id => %{"m.some_config" => %{"other" => "value"}}}}} = User.get(user.id)
    end

    test "cannot put m.fully_read or m.push_rules for any scope", %{user: user} do
      assert {:error, :invalid_type} = User.put_account_data(user.id, :global, "m.fully_read", %{"key" => "value"})
      assert {:error, :invalid_type} = User.put_account_data(user.id, :global, "m.push_rules", %{"key" => "value"})
      {:ok, room_id} = Room.create(user)
      assert {:error, :invalid_type} = User.put_account_data(user.id, room_id, "m.fully_read", %{"other" => "value"})
      assert {:error, :invalid_type} = User.put_account_data(user.id, room_id, "m.push_rules", %{"other" => "value"})
    end

    test "cannot put room account data under a room that doesn't exist", %{user: user} do
      assert {:error, :invalid_room_id} =
               User.put_account_data(user.id, "!huh@localhost", "m.some_config", %{"other" => "value"})
    end

    test "cannot put any account data for an unknown user", %{user: user} do
      assert {:error, :not_found} =
               User.put_account_data("@hellooo:localhost", :global, "m.some_config", %{"key" => "value"})

      {:ok, room_id} = Room.create(user)

      assert {:error, :not_found} =
               User.put_account_data("@hellooo:localhost", room_id, "m.some_config", %{"other" => "value"})
    end
  end

  describe "query_all_keys/2" do
    test "returns all cross-signing and device identity keys if the user is querying their own keys" do
      %{id: user_id} = user = Fixtures.user()
      cross_signing_keys = Fixtures.create_cross_signing_keys(user.id)
      {:ok, user} = User.CrossSigningKeyRing.put(user.id, cross_signing_keys)

      assert %{} = query_result = User.query_all_keys(%{user.id => []}, user.id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["user_signing"]}} = query_result["user_signing_keys"]

      %{id: device_id} = device = Fixtures.device(user.id)
      {:ok, _device} = Device.put_keys(user.id, device.id, identity_keys: Fixtures.device_keys(device.id, user.id))
      assert %{} = query_result = User.query_all_keys(%{user.id => []}, user.id)

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

      assert %{} = query_result = User.query_all_keys(%{user.id => []}, querying.id)
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["master"]}} = query_result["master_keys"]
      assert %{^user_id => %{"user_id" => ^user_id, "usage" => ["self_signing"]}} = query_result["self_signing_keys"]
      refute is_map_key(query_result, "user_signing_keys")

      %{id: device_id} = device = Fixtures.device(user.id)
      {:ok, _device} = Device.put_keys(user.id, device.id, identity_keys: Fixtures.device_keys(device.id, user.id))
      assert %{} = query_result = User.query_all_keys(%{user.id => []}, querying.id)

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
      assert %{} = query_result = User.query_all_keys(%{user.id => []}, querying.id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 3 = map_size(device_keys_map)

      assert %{} = query_result = User.query_all_keys(%{user.id => [device_id1, device_id3]}, querying.id)

      assert %{^user_id => device_keys_map} = query_result["device_keys"]
      assert 2 = map_size(device_keys_map)
      refute Enum.any?(device_keys_map, fn {device_id, _} -> device_id == device_id2 end)
    end
  end

  defp super_long_user_id do
    "@behold_a_bunch_of_underscores_to_get_over_255_chars#{String.duplicate("_", 193)}:servername"
  end
end
