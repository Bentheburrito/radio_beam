defmodule RadioBeam.User.LocalAccountTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.LocalAccount
  alias RadioBeam.User.LocalAccount.State

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
      assert [%State{changed_by_id: ^admin_id} = ls1] = account.state_changes

      epoch = DateTime.from_unix!(0)

      account = LocalAccount.lock(account, admin_id, changed_at: epoch)
      assert [%State{changed_at: ^epoch}, ^ls1] = account.state_changes
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

  defp super_long_user_id do
    "@behold_a_bunch_of_underscores_to_get_over_255_chars#{String.duplicate("_", 193)}:servername"
  end
end
