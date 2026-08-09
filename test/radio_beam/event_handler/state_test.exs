defmodule RadioBeam.EventHandler.StateTest do
  use ExUnit.Case, async: true

  alias RadioBeam.EventHandler
  alias RadioBeam.EventHandler.State
  alias RadioBeam.PubSub

  alias RadioBeam.EventHandler.StateTest.AlwaysSucceeds
  alias RadioBeam.EventHandler.StateTest.FailEveryThird

  setup do
    always_succeeds = {AlwaysSucceeds, Enum.random(0..9_999_999_999)}
    fail_every_3 = {FailEveryThird, Enum.random(0..9_999_999_999)}

    creator_id = Fixtures.user_id()
    room = Fixtures.room("12", creator_id)

    %{always_succeeds_queue: always_succeeds, fail_every_3_queue: fail_every_3, room: room, creator_id: creator_id}
  end

  describe "process_init/1" do
    test "returns `:done` when there are no events on its queue", %{always_succeeds_queue: queue} do
      assert :done = State.process_init(queue)
    end

    test "returns `{:ok, state}` after processing queued events", %{
      always_succeeds_queue: queue,
      room: room,
      creator_id: creator_id
    } do
      PubSub.subscribe(PubSub.read_model_caught_up_to(queue))

      {:sent, _room, _event_id, [%{stream_number: event_num} = pdu]} =
        Fixtures.send_room_msg(room, creator_id, "hullo there")

      assert :ok = EventHandler.queue_event(pdu, queues: [queue], notify?: false)

      assert {:ok, %State{} = state} = State.process_init(queue)
      assert ^queue = State.queue(state)
      assert :good = State.disposition(state)

      assert_received {:read_model_caught_up_to, ^queue, ^event_num, _event_id}
    end
  end

  describe "process/1" do
    setup %{always_succeeds_queue: succeed_queue, fail_every_3_queue: fail_queue, room: room, creator_id: creator_id} do
      {:sent, _room, _event_id, [pdu]} =
        Fixtures.send_room_msg(room, creator_id, "hullo there")

      :ok = EventHandler.queue_event(pdu, queues: [succeed_queue, fail_queue], notify?: false)
      {:ok, %State{} = good_state} = State.process_init(succeed_queue)
      {:ok, %State{} = fail_state} = State.process_init(fail_queue)

      %{good_state: good_state, fail_state: fail_state}
    end

    test "returns `:done` when there are no events on its queue", %{good_state: state} do
      assert :done = State.process(state)
    end

    test "returns `{:ok, state}` after processing queued events", %{
      good_state: state,
      room: room,
      creator_id: creator_id
    } do
      queue = State.queue(state)
      PubSub.subscribe(PubSub.read_model_caught_up_to(queue))

      {:sent, room, _event_id, [pdu1]} = Fixtures.send_room_msg(room, creator_id, "hello?")
      {:sent, _room, _event_id, [pdu2]} = Fixtures.send_room_msg(room, creator_id, "oh there's no one else here yet")

      assert :ok = EventHandler.queue_event(pdu1, queues: [queue], notify?: false)
      assert :ok = EventHandler.queue_event(pdu2, queues: [queue], notify?: false)

      assert {:ok, %State{} = state} = State.process(state)
      assert ^queue = State.queue(state)
      assert :good = State.disposition(state)

      %{stream_number: event_num1} = pdu1
      %{stream_number: event_num2} = pdu2
      assert_received {:read_model_caught_up_to, ^queue, ^event_num1, _event_id}
      refute_received {:read_model_caught_up_to, ^queue, ^event_num2, _event_id}

      assert {:ok, %State{} = state} = State.process(state)
      assert ^queue = State.queue(state)
      assert :good = State.disposition(state)

      assert_received {:read_model_caught_up_to, ^queue, ^event_num2, _event_id}
    end

    test "returns `{:error, state}` after failing to process a queued event", %{
      fail_state: state,
      room: room,
      creator_id: creator_id
    } do
      queue = State.queue(state)
      PubSub.subscribe(PubSub.read_model_caught_up_to(queue))

      {:sent, room, _event_id, [pdu1]} = Fixtures.send_room_msg(room, creator_id, "hello?")
      {:sent, room, _event_id, [pdu2]} = Fixtures.send_room_msg(room, creator_id, "oh there's no one else here yet")

      assert :ok = EventHandler.queue_event(pdu1, queues: [queue], notify?: false)
      assert :ok = EventHandler.queue_event(pdu2, queues: [queue], notify?: false)

      assert {:ok, %State{} = state} = State.process(state)
      assert {:ok, %State{} = state} = State.process(state)
      assert :good = State.disposition(state)

      {:sent, _room, _event_id, [pdu3]} = Fixtures.send_room_msg(room, creator_id, "rip")
      assert :ok = EventHandler.queue_event(pdu3, queues: [queue], notify?: false)

      assert {:error, %State{} = state} = State.process(state)
      assert ^queue = State.queue(state)
      assert {:failing, 1} = State.disposition(state)

      %{stream_number: event_num1} = pdu1
      %{stream_number: event_num2} = pdu2
      %{stream_number: event_num3} = pdu3
      assert_received {:read_model_caught_up_to, ^queue, ^event_num1, _event_id}
      assert_received {:read_model_caught_up_to, ^queue, ^event_num2, _event_id}
      refute_received {:read_model_caught_up_to, ^queue, ^event_num3, _event_id}

      assert {:error, %State{} = state} = State.process(state)
      assert ^queue = State.queue(state)
      assert {:failing, 2} = State.disposition(state)

      refute_received {:read_model_caught_up_to, ^queue, ^event_num3, _event_id}
    end
  end

  describe "validate_queue/1" do
    test "returns `:ok` for valid queues" do
      assert :ok = State.validate_queue(AlwaysSucceeds)
      assert :ok = State.validate_queue({AlwaysSucceeds, 1})
      assert :ok = State.validate_queue({AlwaysSucceeds, 1, 2})
    end

    test "returns `{:error, :invalid_queue}` for invalid queues" do
      for q <- [1, "hi", :whoa, SomeMod, Map, {}, {Map, 1}, self(), make_ref()] do
        assert {:error, :invalid_queue} = State.validate_queue(q)
      end
    end
  end

  defmodule AlwaysSucceeds do
    @behaviour RadioBeam.EventHandler

    @impl RadioBeam.EventHandler
    def handle_pdu(_, _), do: :ok

    @impl RadioBeam.EventHandler
    def reset_to(event_number), do: {:ok, event_number}
  end

  defmodule FailEveryThird do
    @behaviour RadioBeam.EventHandler

    @impl RadioBeam.EventHandler
    def handle_pdu(%{stream_number: event_num}, _) do
      if rem(event_num, 3) != 2, do: :ok, else: {:error, :retry}
    end

    @impl RadioBeam.EventHandler
    def reset_to(event_number), do: {:ok, event_number}
  end
end
