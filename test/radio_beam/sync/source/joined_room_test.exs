defmodule RadioBeam.Sync.Source.JoinedRoomTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.Sync.Source.JoinedRoom
  alias RadioBeam.User.EventFilter

  setup do
    account = Fixtures.create_account()

    %{
      inputs: %{
        user_id: account.user_id,
        account_data: %{},
        event_filter: EventFilter.new(%{}),
        known_memberships: %{},
        last_batch: nil
      }
    }
  end

  describe "run/3 with __MODULE__ as the key" do
    test "will immediately notify_waiting", %{inputs: inputs} do
      me = self()

      Task.start(fn -> JoinedRoom.run(inputs, inspect(JoinedRoom), me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
    end

    test "returns when user joins a new room, after notifying waiting", %{inputs: inputs} do
      me = self()

      task = Task.async(fn -> JoinedRoom.run(inputs, inspect(JoinedRoom), me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      {:ok, _} = Room.invite(room_id, creator_id, inputs.user_id)
      {:ok, join_event_id} = Room.join(room_id, inputs.user_id)

      assert {:ok, %JoinedRoomResult{room_id: ^room_id}, {:next_batch, ^room_id, ^join_event_id}} =
               Task.await(task)
    end
  end
end
