defmodule RadioBeam.User.ClientConfigTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.ClientConfig
  alias RadioBeam.User.Notifications.Core.ConditionalRule
  alias RadioBeam.User.Notifications.Core.Pusher

  describe "put_account_data" do
    setup do
      %{account: Fixtures.create_account()}
    end

    test "successfully puts global account data", %{account: account} do
      config = ClientConfig.new!(account.user_id)

      assert {:ok, %ClientConfig{account_data: %{global: %{"m.some_config" => %{"key" => "value"}}}}} =
               ClientConfig.put_account_data(config, :global, "m.some_config", %{"key" => "value"})
    end

    test "successfully puts room account data", %{account: account} do
      room_id = Fixtures.room_id()

      config = ClientConfig.new!(account.user_id)

      assert {:ok, %ClientConfig{account_data: %{^room_id => %{"m.some_config" => %{"other" => "value"}}}}} =
               ClientConfig.put_account_data(config, room_id, "m.some_config", %{"other" => "value"})
    end

    test "cannot put m.fully_read or m.push_rules for any scope", %{account: account} do
      config = ClientConfig.new!(account.user_id)

      assert {:error, :invalid_type} =
               ClientConfig.put_account_data(config, :global, "m.fully_read", %{"key" => "value"})

      assert {:error, :invalid_type} =
               ClientConfig.put_account_data(config, :global, "m.push_rules", %{"key" => "value"})

      room_id = Fixtures.room_id()
      config = ClientConfig.new!(account.user_id)

      assert {:error, :invalid_type} =
               ClientConfig.put_account_data(config, room_id, "m.fully_read", %{"other" => "value"})

      assert {:error, :invalid_type} =
               ClientConfig.put_account_data(config, room_id, "m.push_rules", %{"other" => "value"})
    end

    test "accepts a function to update content", %{account: account} do
      config = ClientConfig.new!(account.user_id)

      assert {:ok, %ClientConfig{account_data: %{global: %{"m.some_config" => %{"other" => "value"}}}} = config} =
               ClientConfig.put_account_data(config, :global, "m.some_config", %{"other" => "value"})

      assert {:ok,
              %ClientConfig{account_data: %{global: %{"m.some_config" => %{"other" => "value", "another" => "val"}}}}} =
               ClientConfig.put_account_data(config, :global, "m.some_config", &Map.put(&1, "another", "val"))
    end
  end

  describe "put_fully_read/3" do
    setup do
      %{account: Fixtures.create_account()}
    end

    test "writes the given m.fully_read content to a room's account data", %{account: account} do
      config = ClientConfig.new!(account.user_id)
      room_id = Fixtures.room_id()
      content = %{"event_id" => "$someplace:example.org"}

      assert {:ok, %ClientConfig{account_data: %{^room_id => %{"m.fully_read" => ^content}}}} =
               ClientConfig.put_fully_read(config, room_id, content)
    end
  end

  describe "put_notification_pusher/2" do
    setup do
      app_id = "com.a-company.client.matrix.ios"
      pusher_data_params = %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify"}

      {:ok, pusher} = Pusher.new("http", app_id, "abcdeff", "A Company's Client", pusher_data_params, "My iPhone")

      {:ok, pusher2} =
        Pusher.new("email", app_id <> ".email", "someone@somewhere.org", "A Company's Client", %{}, "My iPhone")

      %{
        http_pusher: pusher,
        email_pusher: pusher2
      }
    end

    test "adds a new pusher to the config", %{http_pusher: pusher, email_pusher: pusher2} do
      account = Fixtures.create_account()
      config = ClientConfig.new!(account.user_id)

      assert [] = ClientConfig.get_all_notification_pushers(config)

      config = ClientConfig.put_notification_pusher(config, pusher)
      assert [^pusher] = ClientConfig.get_all_notification_pushers(config)

      config = ClientConfig.put_notification_pusher(config, pusher2)
      assert Enum.sort([pusher, pusher2]) == Enum.sort(ClientConfig.get_all_notification_pushers(config))
    end

    test "updates a pusher under the same { app_id, pushkey} key on the config", %{http_pusher: pusher} do
      account = Fixtures.create_account()
      config = ClientConfig.new!(account.user_id)

      config = ClientConfig.put_notification_pusher(config, pusher)
      assert [^pusher] = ClientConfig.get_all_notification_pushers(config)

      updated_pusher = put_in(pusher.app_display_name, "NEW APP NAME")

      config = ClientConfig.put_notification_pusher(config, updated_pusher)
      assert [^updated_pusher] = ClientConfig.get_all_notification_pushers(config)

      another_updated_pusher = put_in(pusher.profile_tag, "different-tag")

      config = ClientConfig.put_notification_pusher(config, another_updated_pusher)
      assert [^another_updated_pusher] = ClientConfig.get_all_notification_pushers(config)

      new_pusher = put_in(pusher.pushkey, "different-pushkey")

      config = ClientConfig.put_notification_pusher(config, new_pusher)

      assert Enum.sort([another_updated_pusher, new_pusher]) ==
               Enum.sort(ClientConfig.get_all_notification_pushers(config))
    end
  end

  describe "delete_notification_pusher/3" do
    setup do
      app_id = "com.a-company.client.matrix.ios"
      pusher_data_params = %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify"}

      account = Fixtures.create_account()
      config = ClientConfig.new!(account.user_id)

      {:ok, pusher} = Pusher.new("http", app_id, "abcdeff", "A Company's Client", pusher_data_params, "My iPhone")

      {:ok, pusher2} =
        Pusher.new("email", app_id <> ".email", "someone@somewhere.org", "A Company's Client", %{}, "My iPhone")

      config = config |> ClientConfig.put_notification_pusher(pusher) |> ClientConfig.put_notification_pusher(pusher2)

      %{
        http_pusher: pusher,
        email_pusher: pusher2,
        config: config
      }
    end

    test "adds a new pusher to the client config", %{http_pusher: pusher, email_pusher: pusher2, config: config} do
      assert Enum.sort([pusher, pusher2]) == Enum.sort(ClientConfig.get_all_notification_pushers(config))

      config = ClientConfig.delete_notification_pusher(config, pusher.app_id, pusher.pushkey)

      assert [^pusher2] = ClientConfig.get_all_notification_pushers(config)

      config = ClientConfig.delete_notification_pusher(config, pusher2.app_id, pusher2.pushkey)

      assert [] = ClientConfig.get_all_notification_pushers(config)
    end
  end

  describe "put_global_notification_push_rule/4,5" do
    setup do
      account = Fixtures.create_account()
      %{config: ClientConfig.new!(account.user_id)}
    end

    test "successfully puts a valid push rule", %{config: config} do
      for kind <- ~w|override underride|a do
        rule_id = Fixtures.random_string(9)

        assert {:ok, %ClientConfig{} = config} =
                 ClientConfig.put_global_notification_push_rule(config, kind, rule_id, ["notify"], [])

        assert {:ok, %ConditionalRule{} = rule} =
                 ClientConfig.fetch_global_notification_push_rule(config, kind, rule_id)

        assert ^rule_id = ConditionalRule.id(rule)
      end
    end

    @sound_tweak %{"set_tweak" => "sound", "value" => "default"}
    test "successfully updates an existing push rule when only actions are provided", %{config: config} do
      for kind <- ~w|override underride|a do
        rule_id = Fixtures.random_string(9)

        {:ok, %ClientConfig{} = config} =
          ClientConfig.put_global_notification_push_rule(config, kind, rule_id, ["notify"], [])

        {:ok, %ConditionalRule{} = rule} = ClientConfig.fetch_global_notification_push_rule(config, kind, rule_id)
        assert [:notify] = ConditionalRule.actions(rule)

        {:ok, %ClientConfig{} = config} =
          ClientConfig.put_global_notification_push_rule(config, kind, rule_id, [@sound_tweak])

        {:ok, %ConditionalRule{} = rule} = ClientConfig.fetch_global_notification_push_rule(config, kind, rule_id)
        assert [%{set_tweak: "sound", value: "default"}] = ConditionalRule.actions(rule)
      end
    end

    test "rejects invalid push rules", %{config: config} do
      assert {:error, :kind} = ClientConfig.put_global_notification_push_rule(config, :ew, "abcdef", ["notify"], [])
      assert {:error, :rule_id} = ClientConfig.put_global_notification_push_rule(config, :override, 123, ["notify"], [])

      assert {:error, :actions} =
               ClientConfig.put_global_notification_push_rule(config, :override, "bcde", "notify", [])
    end
  end
end
