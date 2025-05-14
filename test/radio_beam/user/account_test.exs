defmodule RadioBeam.User.AccountTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.Account

  describe "put/2" do
    setup do
      %{user: Fixtures.user()}
    end

    test "successfully puts global account data", %{user: user} do
      assert {:ok, %User{account_data: %{global: %{"m.some_config" => %{"key" => "value"}}}}} =
               Account.put(user.id, :global, "m.some_config", %{"key" => "value"})
    end

    test "successfully puts room account data", %{user: user} do
      {:ok, room_id} = Room.create(user)

      assert {:ok, %User{account_data: %{^room_id => %{"m.some_config" => %{"other" => "value"}}}}} =
               Account.put(user.id, room_id, "m.some_config", %{"other" => "value"})
    end

    test "cannot put m.fully_read or m.push_rules for any scope", %{user: user} do
      assert {:error, :invalid_type} = Account.put(user.id, :global, "m.fully_read", %{"key" => "value"})
      assert {:error, :invalid_type} = Account.put(user.id, :global, "m.push_rules", %{"key" => "value"})
      {:ok, room_id} = Room.create(user)
      assert {:error, :invalid_type} = Account.put(user.id, room_id, "m.fully_read", %{"other" => "value"})
      assert {:error, :invalid_type} = Account.put(user.id, room_id, "m.push_rules", %{"other" => "value"})
    end

    test "cannot put room account data under a room that doesn't exist", %{user: user} do
      assert {:error, :invalid_room_id} =
               Account.put(user.id, "!huh@localhost", "m.some_config", %{"other" => "value"})
    end

    test "cannot put any account data for an unknown user", %{user: user} do
      assert {:error, :not_found} =
               Account.put("@hellooo:localhost", :global, "m.some_config", %{"key" => "value"})

      {:ok, room_id} = Room.create(user)

      assert {:error, :not_found} =
               Account.put("@hellooo:localhost", room_id, "m.some_config", %{"other" => "value"})
    end
  end
end
