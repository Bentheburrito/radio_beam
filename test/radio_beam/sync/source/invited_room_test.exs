defmodule RadioBeam.Sync.Source.InvitedRoomTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Sync.Source.InvitedRoom
  alias RadioBeam.User

  setup do
    account = Fixtures.create_account()
    %{inputs: %{user_id: account.user_id, ignored_user_ids: [], last_batch: nil}}
  end

  describe "run/3 with __MODULE__ as the key" do
    test "will immediately notify_waiting", %{inputs: inputs} do
      me = self()

      Task.start(fn -> InvitedRoom.run(inputs, inspect(InvitedRoom), me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
    end

    test "returns when user is invited to a new room, after notifying waiting", %{inputs: inputs} do
      me = self()

      task = Task.async(fn -> InvitedRoom.run(inputs, inspect(InvitedRoom), me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      {:ok, _} = Room.invite(room_id, creator_id, inputs.user_id)

      assert {:ok, %InvitedRoomResult{room_id: ^room_id}, {:next_batch, ^room_id, "sent"}} =
               Task.await(task)
    end

    test "ignores new invites from ignored users", %{inputs: inputs} do
      me = self()

      %{user_id: ignored_id} = Fixtures.create_account()
      User.put_account_data(inputs.user_id, :global, "m.ignored_user_list", %{"ignored_users" => %{ignored_id => %{}}})
      inputs = Map.put(inputs, :ignored_user_ids, [ignored_id])

      task = Task.async(fn -> InvitedRoom.run(inputs, inspect(InvitedRoom), me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      {:ok, room_id} = Room.create(ignored_id)
      {:ok, _} = Room.invite(room_id, ignored_id, inputs.user_id)

      assert is_nil(Task.yield(task, 10))

      %{user_id: other_id} = Fixtures.create_account()
      {:ok, other_room_id} = Room.create(other_id)
      {:ok, _} = Room.invite(other_room_id, other_id, inputs.user_id)

      assert {:ok, %InvitedRoomResult{room_id: ^other_room_id}, {:next_batch, ^other_room_id, "sent"}} =
               Task.await(task)
    end
  end

  describe "run/3 with a room ID as the key" do
    test "returns invite state for the room", %{inputs: inputs} do
      me = self()

      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      {:ok, _} = Room.invite(room_id, creator_id, inputs.user_id)

      assert {:ok, %InvitedRoomResult{room_id: ^room_id}, "sent"} = InvitedRoom.run(inputs, room_id, me)
    end

    test "ignores new invites from ignored users", %{inputs: inputs} do
      me = self()

      %{user_id: ignored_id} = Fixtures.create_account()
      User.put_account_data(inputs.user_id, :global, "m.ignored_user_list", %{"ignored_users" => %{ignored_id => %{}}})
      inputs = Map.put(inputs, :ignored_user_ids, [ignored_id])
      {:ok, room_id} = Room.create(ignored_id)
      {:ok, _} = Room.invite(room_id, ignored_id, inputs.user_id)

      assert {:no_update, nil} = InvitedRoom.run(inputs, room_id, me)

      %{user_id: other_id} = Fixtures.create_account()
      {:ok, other_room_id} = Room.create(other_id)
      {:ok, _} = Room.invite(other_room_id, other_id, inputs.user_id)

      assert {:ok, %InvitedRoomResult{room_id: ^other_room_id}, "sent"} = InvitedRoom.run(inputs, other_room_id, me)
    end
  end
end
