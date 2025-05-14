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

  describe "strong_password?/1" do
    @special_chars ~w|! @ # $ % ^ & * ( ) _ - + = { [ } ] \| \ : ; " ' < , > . ? /|
    @digits ~w|1 2 3 4 5 6 7 8 9 0|
    @letters ~w|a b c d e f g h i j k l m n o p q r s t u v w x y z|
    @upper_letters Enum.map(@letters, &String.upcase/1)

    test "returns true for passwords that satisfy the regex" do
      for _ <- 1..100, sets <- [Enum.shuffle([@special_chars, @digits, @letters, @upper_letters])] do
        password =
          for set <- sets, character <- Enum.take_random(set, Enum.random(2..6)), into: "" do
            character
          end

        assert {_, true} = {password, User.strong_password?(password)}
      end
    end

    test "returns false for passwords that don't satisfy the regex" do
      for _ <- 1..100, sets <- [Enum.shuffle([@special_chars, @digits, @letters, @upper_letters])] do
        password =
          for set <- Enum.take(sets, 3), character <- Enum.take_random(set, Enum.random(3..6)), into: "" do
            character
          end

        assert {_, false} = {password, User.strong_password?(password)}
      end
    end

    # too short
    refute User.strong_password?("t00SML!")
  end

  describe "put_account_data" do
    setup do
      %{user: Fixtures.user()}
    end

    test "successfully puts global account data", %{user: user} do
      assert {:ok, %User{account_data: %{global: %{"m.some_config" => %{"key" => "value"}}}}} =
               User.put_account_data(user, :global, "m.some_config", %{"key" => "value"})
    end

    test "successfully puts room account data", %{user: user} do
      room_id = Room.generate_id()

      assert {:ok, %User{account_data: %{^room_id => %{"m.some_config" => %{"other" => "value"}}}}} =
               User.put_account_data(user, room_id, "m.some_config", %{"other" => "value"})
    end

    test "cannot put m.fully_read or m.push_rules for any scope", %{user: user} do
      assert {:error, :invalid_type} = User.put_account_data(user, :global, "m.fully_read", %{"key" => "value"})
      assert {:error, :invalid_type} = User.put_account_data(user, :global, "m.push_rules", %{"key" => "value"})
      room_id = Room.generate_id()
      assert {:error, :invalid_type} = User.put_account_data(user, room_id, "m.fully_read", %{"other" => "value"})
      assert {:error, :invalid_type} = User.put_account_data(user, room_id, "m.push_rules", %{"other" => "value"})
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
