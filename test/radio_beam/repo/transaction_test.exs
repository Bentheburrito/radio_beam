defmodule RadioBeam.Repo.TransactionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias RadioBeam.Repo.Transaction

  describe "new/0" do
    test "simply creates a new %Transaction{}" do
      assert %Transaction{} = Transaction.new()
    end
  end

  describe "new/1" do
    test "creates a new %Transaction{} from the given {name, function} pairs" do
      assert %Transaction{} = Transaction.new(for i <- 1..3, do: {"new/1_#{i}", &ok_ident/1})
    end

    test "raises when the given list is not all {name, function} pairs" do
      assert_raise FunctionClauseError, fn -> Transaction.new(for i <- 1..3, do: {"new/1_raise_#{i}", &ok_ident2/2}) end
    end
  end

  describe "add_fxn/3" do
    test "successfully adds a {name, function/1} pair" do
      txn = Transaction.new()

      assert %Transaction{} = Transaction.add_fxn(txn, "add_fxn_success", &ok_ident/1)
    end

    test "successfully adds a {name, function/0} pair" do
      txn = Transaction.new()

      assert %Transaction{} = Transaction.add_fxn(txn, "add_fxn_success", &ok/0)
    end

    test "raises when the given arguments are not {name, function} pairs" do
      txn = Transaction.new()

      assert_raise FunctionClauseError, fn -> Transaction.add_fxn(txn, "add_fxn_raise", &ok_ident2/2) end
    end
  end

  describe "execute/1" do
    test "successfully executes a %Transaction{}" do
      txn = Transaction.new([{"execute_ok_1", &ok_count/1}, {"execute_ok_2", &ok_count/1}])

      assert {:ok, 2} = Transaction.execute(txn)
    end

    test "aborts when a function returns an :error tuple, providing its name and the error" do
      txn = Transaction.new([{"execute_ok_uh_oh_later", &ok_count/1}, {"uh oh", &err_ident/1}])

      assert {:error, "uh oh", 1} = Transaction.execute(txn)
    end

    test "aborts when a function raises" do
      txn = Transaction.new([{"I hope nothing blows up", &ok_count/1}, {"OH NO", &boom/1}])

      assert {:error, "OH NO", %RuntimeError{message: "BOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOM"}} = Transaction.execute(txn)
    end

    test "reports a fatal error (something seriously wrong - mnesia table does not exist)" do
      txn =
        Transaction.new([{"good this succeeds", &ok_count/1}, {"you won't see this", &err_no_table/1}])

      logs =
        capture_log(fn ->
          assert_raise RuntimeError, fn -> Transaction.execute(txn) end
        end)

      assert logs =~ "error occurred running the following"
    end
  end

  defp ok_ident(thing), do: {:ok, thing}
  defp ok_ident2(thing, another_thing), do: {:ok, thing, another_thing}

  defp ok_count(:txn_begin), do: {:ok, 1}
  defp ok_count(num) when is_number(num), do: {:ok, num + 1}

  defp ok, do: {:ok, :whatever}

  defp err_ident(thing), do: {:error, thing}

  defp boom(_thing), do: raise("BOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOM")

  defp err_no_table(_thing) do
    Memento.Query.read(:yea_this_is_not_a_table, 123)
  end
end
