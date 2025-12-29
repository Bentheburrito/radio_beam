defmodule RadioBeam.User.ClientConfigTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.ClientConfig

  describe "put_account_data" do
    setup do
      %{user: Fixtures.user()}
    end

    test "successfully puts global account data", %{user: user} do
      config = ClientConfig.new!(user.id)

      assert {:ok, %ClientConfig{account_data: %{global: %{"m.some_config" => %{"key" => "value"}}}}} =
               ClientConfig.put_account_data(config, :global, "m.some_config", %{"key" => "value"})
    end

    test "successfully puts room account data", %{user: user} do
      room_id = Fixtures.room_id()

      config = ClientConfig.new!(user.id)

      assert {:ok, %ClientConfig{account_data: %{^room_id => %{"m.some_config" => %{"other" => "value"}}}}} =
               ClientConfig.put_account_data(config, room_id, "m.some_config", %{"other" => "value"})
    end

    test "cannot put m.fully_read or m.push_rules for any scope", %{user: user} do
      assert {:error, :invalid_type} = ClientConfig.put_account_data(user, :global, "m.fully_read", %{"key" => "value"})
      assert {:error, :invalid_type} = ClientConfig.put_account_data(user, :global, "m.push_rules", %{"key" => "value"})
      room_id = Fixtures.room_id()
      config = ClientConfig.new!(user.id)

      assert {:error, :invalid_type} =
               ClientConfig.put_account_data(config, room_id, "m.fully_read", %{"other" => "value"})

      assert {:error, :invalid_type} =
               ClientConfig.put_account_data(config, room_id, "m.push_rules", %{"other" => "value"})
    end
  end
end
