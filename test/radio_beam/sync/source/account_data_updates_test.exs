defmodule RadioBeam.Sync.Source.AccountDataUpdatesTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Sync.Source.AccountDataUpdates
  alias RadioBeam.User

  describe "run/3" do
    setup do
      account = Fixtures.create_account()
      %{inputs: %{user_id: account.user_id, last_batch: nil}}
    end

    test "will immediately notify_waiting", %{inputs: inputs} do
      me = self()

      Task.start(fn -> AccountDataUpdates.run(inputs, AccountDataUpdates, me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
    end

    test "returns when account data is updated", %{inputs: inputs} do
      me = self()

      task = Task.async(fn -> AccountDataUpdates.run(inputs, AccountDataUpdates, me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      User.put_account_data(inputs.user_id, :global, "org.company.some.event", %{"the" => "content"})

      assert {:ok, %{"org.company.some.event" => %{"the" => "content"}}, nil} = Task.await(task)
    end
  end
end
