defmodule RadioBeam.Sync.Source.ParticipatingRoomTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.EphemeralState
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.Sync.Source.ParticipatingRoom
  alias RadioBeam.User.EventFilter

  setup do
    account = Fixtures.create_account()
    device = Fixtures.create_device(account.user_id)

    {:ok, room_id} = Room.create(account.user_id)

    queue = {RadioBeam.Room.UserTimeline, room_id}
    Fixtures.listen_to_queue_messages(queue)

    {:ok, event_id} = Room.send_text_message(room_id, account.user_id, "ah, a new room.")

    Fixtures.assert_caught_up_to_event(queue, event_id)

    %{
      inputs: %{
        account_data: %{},
        user_id: account.user_id,
        device_id: device.id,
        ignored_user_ids: [],
        event_filter: EventFilter.new(%{}),
        known_memberships: %{},
        full_state?: false,
        last_batch: nil
      },
      room_id: room_id,
      queue: queue
    }
  end

  describe "run/3" do
    test "returns a JoinedRoomResult", %{inputs: inputs, room_id: room_id} do
      me = self()

      :ok = ParticipatingRoom.init(inputs, room_id)

      assert {:ok, %JoinedRoomResult{room_id: ^room_id, timeline_events: events}, "$" <> _ = _event_id} =
               ParticipatingRoom.run(inputs, room_id, me)

      assert 7 = length(events)
    end

    test "notifies waiting, then returns a JoinedRoomResult after waiting for a new room event", %{
      inputs: inputs,
      room_id: room_id,
      queue: queue
    } do
      me = self()
      :ok = ParticipatingRoom.init(inputs, room_id)

      assert {:ok, %JoinedRoomResult{room_id: ^room_id}, event_id} = ParticipatingRoom.run(inputs, room_id, me)

      task =
        Task.async(fn ->
          :ok = ParticipatingRoom.init(inputs, room_id)
          inputs |> Map.put(:last_batch, event_id) |> ParticipatingRoom.run(room_id, me)
        end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      {:ok, msg_event_id} = Room.send_text_message(room_id, inputs.user_id, "hellooooooooooooooooooooooo")
      Fixtures.assert_caught_up_to_event(queue, msg_event_id)

      assert {:ok, %JoinedRoomResult{room_id: ^room_id, timeline_events: [%{id: ^msg_event_id}]}, ^msg_event_id} =
               Task.await(task)
    end

    test "notifies waiting, then returns a JoinedRoomResult after waiting for a new typing event", %{
      inputs: inputs,
      room_id: room_id
    } do
      me = self()
      :ok = ParticipatingRoom.init(inputs, room_id)

      assert {:ok, %JoinedRoomResult{room_id: ^room_id}, event_id} = ParticipatingRoom.run(inputs, room_id, me)

      task =
        Task.async(fn ->
          :ok = ParticipatingRoom.init(inputs, room_id)
          inputs |> Map.put(:last_batch, event_id) |> ParticipatingRoom.run(room_id, me)
        end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      EphemeralState.put_typing(room_id, inputs.user_id)

      assert {:ok, %JoinedRoomResult{room_id: ^room_id, timeline_events: [], typing: typing}, ^event_id} =
               Task.await(task)

      assert [inputs.user_id] == typing
    end
  end
end
