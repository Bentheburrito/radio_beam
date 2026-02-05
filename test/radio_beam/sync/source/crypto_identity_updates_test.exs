defmodule RadioBeam.Sync.Source.CryptoIdentityUpdatesTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Sync.NextBatch
  alias RadioBeam.Sync.Source.CryptoIdentityUpdates

  describe "run/3" do
    setup do
      account = Fixtures.create_account()
      %{inputs: %{user_id: account.user_id, full_last_batch: nil}}
    end

    test "will notify_waiting if there are no immediate updates", %{inputs: inputs} do
      me = self()

      Task.start(fn -> CryptoIdentityUpdates.run(inputs, CryptoIdentityUpdates, me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
    end

    test "returns when changes are available, without notifying waiting", %{inputs: inputs} do
      me = self()
      creator_id = add_to_new_room(inputs.user_id)
      add_device_keys(creator_id)

      task = Task.async(fn -> CryptoIdentityUpdates.run(inputs, CryptoIdentityUpdates, me) end)

      refute_receive {:sync_waiting, _}
      assert {:ok, %{changed: [^creator_id], left: []}, nil} = Task.await(task)
    end

    test "returns once device-key changes are available, after notifying waiting", %{inputs: inputs} do
      me = self()

      task = Task.async(fn -> CryptoIdentityUpdates.run(inputs, CryptoIdentityUpdates, me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      creator_id = add_to_new_room(inputs.user_id)
      add_device_keys(creator_id)

      assert {:ok, %{changed: [^creator_id], left: []}, nil} = Task.await(task)
    end

    test "returns once cross-signing changes are available, after notifying waiting", %{inputs: inputs} do
      me = self()

      task = Task.async(fn -> CryptoIdentityUpdates.run(inputs, CryptoIdentityUpdates, me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      creator_id = add_to_new_room(inputs.user_id)
      {cross_signing_keys, _privkeys} = Fixtures.create_cross_signing_keys(creator_id)
      {:ok, _key_ring} = RadioBeam.User.KeyStore.put_cross_signing_keys(creator_id, cross_signing_keys)

      assert {:ok, %{changed: [^creator_id], left: []}, nil} = Task.await(task)
    end

    test "returns when membership changes, after notifying waiting", %{inputs: inputs} do
      me = self()

      creator_id = add_to_new_room(inputs.user_id)
      add_device_keys(creator_id)

      [room_id] = creator_id |> Room.joined() |> Enum.to_list()
      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "yo")

      next_batch = :millisecond |> System.os_time() |> Kernel.+(1) |> NextBatch.new!(%{room_id => event_id})

      task =
        Task.async(fn ->
          inputs
          |> Map.put(:full_last_batch, next_batch)
          |> CryptoIdentityUpdates.run(CryptoIdentityUpdates, me)
        end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      {:ok, _event_id} = Room.leave(room_id, creator_id)

      assert {:ok, %{changed: [], left: [^creator_id]}, nil} = Task.await(task)

      {:ok, room_id} = Room.create(inputs.user_id)
      {:ok, event_id} = Room.invite(room_id, inputs.user_id, creator_id)
      {:ok, _event_id} = Room.join(room_id, creator_id)

      next_batch = :millisecond |> System.os_time() |> Kernel.+(1) |> NextBatch.new!(%{room_id => event_id})

      task =
        Task.async(fn ->
          inputs
          |> Map.put(:full_last_batch, next_batch)
          |> CryptoIdentityUpdates.run(CryptoIdentityUpdates, me)
        end)

      assert {:ok, %{changed: [^creator_id], left: []}, nil} = Task.await(task)
    end
  end

  defp add_to_new_room(user_id) do
    %{user_id: creator_id} = Fixtures.create_account()
    {:ok, room_id} = Room.create(creator_id)
    {:ok, _event_id} = Room.invite(room_id, creator_id, user_id)
    {:ok, _event_id} = Room.join(room_id, user_id)

    creator_id
  end

  defp add_device_keys(user_id) do
    device = Fixtures.create_device(user_id)
    Fixtures.create_and_put_device_keys(user_id, device.id)
  end
end
