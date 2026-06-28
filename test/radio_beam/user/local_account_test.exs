defmodule RadioBeam.User.LocalAccountTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.LocalAccount
  alias RadioBeam.User.LocalAccount.State
  alias RadioBeam.User.Notifications.Core.Pusher

  describe "new/1" do
    @password "Ar3allyg00dpwd!@#$"
    test "can create a new local account from params with a valid user ID" do
      valid_ids = [
        "@hello:world",
        "@greetings_sir123:inter.net",
        "@_xcoolguy9x_:servername",
        "@+=-_/somehowvalid:ok.com",
        "@snowful:matrix.org"
      ]

      for id <- valid_ids, do: assert({:ok, %LocalAccount{user_id: ^id}} = LocalAccount.new(id, @password))
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

      for id <- invalid_ids, do: assert({:error, _} = LocalAccount.new(id, @password))
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

        assert {_, true} = {password, LocalAccount.strong_password?(password)}
      end
    end

    test "returns false for passwords that don't satisfy the regex" do
      for _ <- 1..100, sets <- [Enum.shuffle([@special_chars, @digits, @letters, @upper_letters])] do
        password =
          for set <- Enum.take(sets, 3), character <- Enum.take_random(set, Enum.random(3..6)), into: "" do
            character
          end

        assert {_, false} = {password, LocalAccount.strong_password?(password)}
      end
    end

    # too short
    refute LocalAccount.strong_password?("t00SML!")
  end

  describe "lock/2,3" do
    test "adds a new %State{} to the account's `:state_changes`" do
      account = Fixtures.create_account()
      assert [] = account.state_changes

      admin_id = Fixtures.user_id()

      account = LocalAccount.lock(account, admin_id)
      assert [%State{state_name: :locked, changed_by_id: ^admin_id} = ls1] = account.state_changes

      epoch = DateTime.from_unix!(0)

      account = LocalAccount.lock(account, admin_id, changed_at: epoch)
      assert [%State{state_name: :locked, changed_at: ^epoch}, ^ls1] = account.state_changes
    end
  end

  describe "locked?/1,2" do
    test "returns `true` if the given account is considered locked at the given `at` DateTime, and `false` otherwise" do
      account = Fixtures.create_account()
      admin_id = Fixtures.user_id()

      changed_at = DateTime.utc_now()
      effective_until = DateTime.add(changed_at, 1, :day)

      refute LocalAccount.locked?(account)

      account = LocalAccount.lock(account, admin_id, changed_at: changed_at, effective_until: effective_until)

      assert LocalAccount.locked?(account)
      assert LocalAccount.locked?(account, DateTime.utc_now())
      assert LocalAccount.locked?(account, changed_at)
      assert LocalAccount.locked?(account, effective_until)
      assert LocalAccount.locked?(account, DateTime.add(changed_at, 1, :minute))
      assert LocalAccount.locked?(account, DateTime.add(effective_until, -1, :minute))

      refute LocalAccount.locked?(account, DateTime.add(changed_at, -1, :minute))
      refute LocalAccount.locked?(account, DateTime.add(effective_until, 1, :minute))
      refute LocalAccount.locked?(account, DateTime.from_unix!(0))

      account = LocalAccount.lock(account, admin_id, changed_at: changed_at)

      assert LocalAccount.locked?(account)
      assert LocalAccount.locked?(account, DateTime.utc_now())
      assert LocalAccount.locked?(account, changed_at)
      assert LocalAccount.locked?(account, effective_until)
      assert LocalAccount.locked?(account, DateTime.add(changed_at, 1, :minute))
      assert LocalAccount.locked?(account, DateTime.add(effective_until, -1, :minute))

      refute LocalAccount.locked?(account, DateTime.add(changed_at, -1, :minute))
      # effective_until defaults to :infinity
      assert LocalAccount.locked?(account, DateTime.add(effective_until, 1, :minute))
      refute LocalAccount.locked?(account, DateTime.from_unix!(0))
    end
  end

  describe "suspend/2,3" do
    test "adds a new %State{} to the account's `:state_changes`" do
      account = Fixtures.create_account()
      assert [] = account.state_changes

      admin_id = Fixtures.user_id()

      account = LocalAccount.suspend(account, admin_id)
      assert [%State{state_name: :suspended, changed_by_id: ^admin_id} = ls1] = account.state_changes

      epoch = DateTime.from_unix!(0)

      account = LocalAccount.suspend(account, admin_id, changed_at: epoch)
      assert [%State{state_name: :suspended, changed_at: ^epoch}, ^ls1] = account.state_changes
    end
  end

  describe "suspended?/1,2" do
    test "returns `true` if the given account is suspended at the given `at` DateTime, and `false` otherwise" do
      account = Fixtures.create_account()
      admin_id = Fixtures.user_id()

      changed_at = DateTime.utc_now()
      effective_until = DateTime.add(changed_at, 1, :day)

      refute LocalAccount.suspended?(account)

      account = LocalAccount.suspend(account, admin_id, changed_at: changed_at, effective_until: effective_until)

      assert LocalAccount.suspended?(account)
      assert LocalAccount.suspended?(account, DateTime.utc_now())
      assert LocalAccount.suspended?(account, changed_at)
      assert LocalAccount.suspended?(account, effective_until)
      assert LocalAccount.suspended?(account, DateTime.add(changed_at, 1, :minute))
      assert LocalAccount.suspended?(account, DateTime.add(effective_until, -1, :minute))

      refute LocalAccount.suspended?(account, DateTime.add(changed_at, -1, :minute))
      refute LocalAccount.suspended?(account, DateTime.add(effective_until, 1, :minute))
      refute LocalAccount.suspended?(account, DateTime.from_unix!(0))

      account = LocalAccount.suspend(account, admin_id, changed_at: changed_at)

      assert LocalAccount.suspended?(account)
      assert LocalAccount.suspended?(account, DateTime.utc_now())
      assert LocalAccount.suspended?(account, changed_at)
      assert LocalAccount.suspended?(account, effective_until)
      assert LocalAccount.suspended?(account, DateTime.add(changed_at, 1, :minute))
      assert LocalAccount.suspended?(account, DateTime.add(effective_until, -1, :minute))

      refute LocalAccount.suspended?(account, DateTime.add(changed_at, -1, :minute))
      # effective_until defaults to :infinity
      assert LocalAccount.suspended?(account, DateTime.add(effective_until, 1, :minute))
      refute LocalAccount.suspended?(account, DateTime.from_unix!(0))
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

    test "adds a new pusher to the account", %{http_pusher: pusher, email_pusher: pusher2} do
      account = Fixtures.create_account()
      assert [] = LocalAccount.get_all_notification_pushers(account)

      account = LocalAccount.put_notification_pusher(account, pusher)
      assert [^pusher] = LocalAccount.get_all_notification_pushers(account)

      account = LocalAccount.put_notification_pusher(account, pusher2)
      assert Enum.sort([pusher, pusher2]) == Enum.sort(LocalAccount.get_all_notification_pushers(account))
    end

    test "updates a pusher under the same { app_id, pushkey} key on the account", %{http_pusher: pusher} do
      account = Fixtures.create_account()

      account = LocalAccount.put_notification_pusher(account, pusher)
      assert [^pusher] = LocalAccount.get_all_notification_pushers(account)

      updated_pusher = put_in(pusher.app_display_name, "NEW APP NAME")

      account = LocalAccount.put_notification_pusher(account, updated_pusher)
      assert [^updated_pusher] = LocalAccount.get_all_notification_pushers(account)

      another_updated_pusher = put_in(pusher.profile_tag, "different-tag")

      account = LocalAccount.put_notification_pusher(account, another_updated_pusher)
      assert [^another_updated_pusher] = LocalAccount.get_all_notification_pushers(account)

      new_pusher = put_in(pusher.pushkey, "different-pushkey")

      account = LocalAccount.put_notification_pusher(account, new_pusher)

      assert Enum.sort([another_updated_pusher, new_pusher]) ==
               Enum.sort(LocalAccount.get_all_notification_pushers(account))
    end
  end

  describe "delete_notification_pusher/3" do
    setup do
      app_id = "com.a-company.client.matrix.ios"
      pusher_data_params = %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify"}

      account = Fixtures.create_account()

      {:ok, pusher} = Pusher.new("http", app_id, "abcdeff", "A Company's Client", pusher_data_params, "My iPhone")

      {:ok, pusher2} =
        Pusher.new("email", app_id <> ".email", "someone@somewhere.org", "A Company's Client", %{}, "My iPhone")

      account = account |> LocalAccount.put_notification_pusher(pusher) |> LocalAccount.put_notification_pusher(pusher2)

      %{
        http_pusher: pusher,
        email_pusher: pusher2,
        account: account
      }
    end

    test "adds a new pusher to the account", %{http_pusher: pusher, email_pusher: pusher2, account: account} do
      assert Enum.sort([pusher, pusher2]) == Enum.sort(LocalAccount.get_all_notification_pushers(account))

      account = LocalAccount.delete_notification_pusher(account, pusher.app_id, pusher.pushkey)

      assert [^pusher2] = LocalAccount.get_all_notification_pushers(account)

      account = LocalAccount.delete_notification_pusher(account, pusher2.app_id, pusher2.pushkey)

      assert [] = LocalAccount.get_all_notification_pushers(account)
    end
  end

  defp super_long_user_id do
    "@behold_a_bunch_of_underscores_to_get_over_255_chars#{String.duplicate("_", 193)}:servername"
  end
end
