defmodule RadioBeam.TransactionTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Transaction

  test "can manage a single simple request" do
    assert {:ok, handle} = Transaction.begin("1234", "abcd", "/_matrix/client/v3/some-endpoint")
    assert :ok = Transaction.done(handle, :all_done)
  end

  test "can manage two simple distinct request" do
    assert {:ok, handle} = Transaction.begin("1234", "abcd", "/_matrix/client/v3/some-new-endpoint")
    assert :ok = Transaction.done(handle, :all_done)
    assert {:ok, handle} = Transaction.begin("22345", "abcd", "/_matrix/client/v3/some-different-endpoint")
    assert :ok = Transaction.done(handle, :all_done!)
  end

  test "can manage a followup duplicate request" do
    assert {:ok, handle} = Transaction.begin("1234", "abcd", "/_matrix/client/v3/some-other-endpoint")
    assert :ok = Transaction.done(handle, :all_done)

    assert {:already_done, :all_done} = Transaction.begin("1234", "abcd", "/_matrix/client/v3/some-other-endpoint")
  end

  test "can manage two concurrent duplicate requests" do
    assert {:ok, handle} = Transaction.begin("1234", "abcd", "/_matrix/client/v3/yet-another-endpoint")
    task = Task.async(fn -> Transaction.begin("1234", "abcd", "/_matrix/client/v3/yet-another-endpoint") end)

    assert :ok = Transaction.done(handle, :all_done)
    assert {:already_done, :all_done} = Task.await(task)
  end

  test "can manage a single request abort" do
    assert {:ok, handle} = Transaction.begin("1234", "", "/_matrix/client/v3/failing-endpoint")
    assert :ok = Transaction.abort(handle)
    assert {:ok, handle} = Transaction.begin("1234", "", "/_matrix/client/v3/failing-endpoint")
    Transaction.abort(handle)
  end

  test "can manage a request abort with two concurrent requests" do
    assert {:ok, handle} = Transaction.begin("1234", "abcd", "/_matrix/client/v3/2-failing-endpoint")
    task = Task.async(fn -> Transaction.begin("1234", "abcd", "/_matrix/client/v3/2-failing-endpoint") end)
    assert :ok = Transaction.abort(handle)
    assert {:ok, handle} = Task.await(task)
    :ok = Transaction.done(handle, :all_done)
  end
end
