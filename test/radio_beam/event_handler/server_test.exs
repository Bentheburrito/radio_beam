defmodule RadioBeam.EventHandler.ServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias RadioBeam.EventHandler
  alias RadioBeam.EventHandler.Server
  alias RadioBeam.PubSub

  alias RadioBeam.EventHandler.ServerTest.AlwaysSucceeds
  alias RadioBeam.EventHandler.ServerTest.FlakeySuccess

  setup do
    always_succeeds = {AlwaysSucceeds, Enum.random(0..9_999_999_999)}
    flakey_success = {FlakeySuccess, Enum.random(0..9_999_999_999)}

    creator_id = Fixtures.user_id()
    room = Fixtures.room("12", creator_id)

    %{always_succeeds_queue: always_succeeds, flakey_success_queue: flakey_success, room: room, creator_id: creator_id}
  end

  test "simply terminates normally when starting with no work to do", %{always_succeeds_queue: queue} do
    Process.flag(:trap_exit, true)
    {:ok, pid} = Server.start_link(queue)
    assert_receive {:EXIT, ^pid, :normal}
    refute Process.alive?(pid)
  end

  describe "a server with a healthy callback mod" do
    test "successfully processes all queued messages, then waits for more", %{
      always_succeeds_queue: queue,
      room: room,
      creator_id: creator_id
    } do
      PubSub.subscribe(PubSub.read_model_caught_up_to(queue))

      {:sent, room, _event_id, [pdu1]} = Fixtures.send_room_msg(room, creator_id, "hello?")
      {:sent, _room, _event_id, [pdu2]} = Fixtures.send_room_msg(room, creator_id, "oh there's no one else here yet")

      assert :ok = EventHandler.queue_event(pdu1, queues: [queue], notify?: false)
      assert :ok = EventHandler.queue_event(pdu2, queues: [queue], notify?: false)

      assert {:ok, _, _} = RadioBeam.Database.peek_event(queue)

      %{stream_number: event_num1} = pdu1
      %{stream_number: event_num2} = pdu2
      refute_receive {:read_model_caught_up_to, ^queue, ^event_num1, _event_id}
      refute_receive {:read_model_caught_up_to, ^queue, ^event_num2, _event_id}

      assert :ok = Server.notify_event_queued(queue)

      assert_receive {:read_model_caught_up_to, ^queue, ^event_num1, _event_id}
      assert_receive {:read_model_caught_up_to, ^queue, ^event_num2, _event_id}

      assert :done = RadioBeam.Database.peek_event(queue)

      assert [{pid, nil}] = Registry.lookup(Server.registry(), queue)
      assert Process.alive?(pid)
    end
  end

  describe "a server with a fallable callback mod" do
    test "successfully works through intermittent callback errors", %{
      flakey_success_queue: queue,
      room: room,
      creator_id: creator_id
    } do
      {_room, last_event_num} =
        Enum.reduce(1..10, {room, nil}, fn _i, {room, _} ->
          {:sent, room, _event_id, [pdu]} = Fixtures.send_room_msg(room, creator_id, "hello?")
          :ok = EventHandler.queue_event(pdu, queues: [queue], notify?: false)
          {room, pdu.stream_number}
        end)

      PubSub.subscribe(PubSub.read_model_caught_up_to(queue))
      Process.flag(:trap_exit, true)

      logs =
        capture_log(fn ->
          pid = start_supervised!({Server, queue})

          assert :ok = Server.notify_event_queued(queue)

          assert_receive {:read_model_caught_up_to, ^queue, ^last_event_num, _event_id}, :timer.seconds(1)
          assert :done = RadioBeam.Database.peek_event(queue)

          refute_receive {:EXIT, ^pid, _any_reason}
          assert Process.alive?(pid)
        end)

      assert logs =~ "failed 1 times"
      assert logs =~ "trying to process event after failing"
      assert logs =~ "has recovered!"
    end
  end

  defmodule AlwaysSucceeds do
    @behaviour RadioBeam.EventHandler

    @impl RadioBeam.EventHandler
    def handle_pdu(_, _), do: :ok

    @impl RadioBeam.EventHandler
    def reset_to(event_number), do: {:ok, event_number}
  end

  defmodule FlakeySuccess do
    @behaviour RadioBeam.EventHandler

    @impl RadioBeam.EventHandler
    def handle_pdu(_, _) do
      if Enum.random([1, 2]) == 1, do: :ok, else: {:error, :retry}
    end

    @impl RadioBeam.EventHandler
    def reset_to(event_number), do: {:ok, event_number}
  end
end
