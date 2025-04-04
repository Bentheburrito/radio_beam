defmodule RadioBeam.UserTest do
  use ExUnit.Case, async: true

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
      assert {:ok, ^user} = User.put_new(user)
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

  describe "get_device/2" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "returns a user's device", %{user: user, device: %{id: device_id} = device} do
      assert {:ok, %User.Device{id: ^device_id}} = User.get_device(user, device.id)
    end

    test "returns an error if not device is found for a valid user", %{user: user} do
      assert {:error, :not_found} = User.get_device(user, "does not exist")
    end
  end

  describe "get_all_devices/2" do
    setup do
      user = Fixtures.user()
      {user, _device} = Fixtures.device(user)
      {user, _device} = Fixtures.device(user)

      %{user: user, user_no_devices: Fixtures.user()}
    end

    test "gets all of a user's devices", %{user: user, user_no_devices: user2} do
      assert devices = User.get_all_devices(user)
      assert 2 = length(devices)
      assert [] = User.get_all_devices(user2)
    end
  end

  defp super_long_user_id do
    "@behold_a_bunch_of_underscores_to_get_over_255_chars#{String.duplicate("_", 193)}:servername"
  end
end
