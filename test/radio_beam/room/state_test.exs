defmodule RadioBeam.Room.StateTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.State

  describe "handle_pdu/2" do
    test "puts a state event PDU in the mapping under {event.type, event.state_key}" do
      create_pdu = Fixtures.authz_create_event() |> PDU.new!([], 0)

      %State{} = state = State.new!()
      assert :error = Map.fetch(state.mapping, {create_pdu.event.type, create_pdu.event.state_key})
      %State{} = state = State.handle_pdu(state, create_pdu)
      assert {:ok, [^create_pdu]} = Map.fetch(state.mapping, {create_pdu.event.type, create_pdu.event.state_key})
    end

    test "puts a state event PDU in the mapping, superceding a previous state event" do
      room_id = Fixtures.room_id()
      user_id = Fixtures.user_id()

      first_membership_pdu =
        room_id |> Events.membership(user_id, user_id, :join) |> Fixtures.authz_event([]) |> PDU.new!([], 0)

      %State{} = state = State.handle_pdu(State.new!(), first_membership_pdu)
      assert {:ok, [^first_membership_pdu]} = Map.fetch(state.mapping, {"m.room.member", user_id})

      second_membership_pdu =
        room_id
        |> Events.membership(user_id, user_id, :join)
        |> Fixtures.authz_event([])
        |> PDU.new!([first_membership_pdu.event.id], 1)

      %State{} = state = State.handle_pdu(state, second_membership_pdu)

      assert {:ok, [^second_membership_pdu, ^first_membership_pdu]} =
               Map.fetch(state.mapping, {"m.room.member", user_id})
    end

    test "ignores message events" do
      message_pdu =
        Fixtures.authz_message_event(Fixtures.room_id(), Fixtures.user_id(), [], "hello world") |> PDU.new!([], 0)

      state = State.new!()
      assert 0 = map_size(state.mapping)
      %State{} = state = State.handle_pdu(state, message_pdu)
      assert 0 = map_size(state.mapping)
    end
  end

  describe "fetch/2,3" do
    test "returns {:error, :not_found} when no state event of the given key has been sent in the room" do
      assert {:error, :not_found} = State.fetch(State.new!(), "m.room.join_rules")
      assert {:error, :not_found} = State.fetch(State.new!(), "m.room.join_rules", "")
    end

    test "returns {:ok, pdu} when one PDU of the given key has been sent in the room" do
      create_pdu = Fixtures.authz_create_event() |> PDU.new!([], 0)

      %State{} = state = State.new!()
      assert {:error, :not_found} = State.fetch(state, create_pdu.event.type, create_pdu.event.state_key)
      %State{} = state = State.handle_pdu(state, create_pdu)
      assert {:ok, ^create_pdu} = State.fetch(state, create_pdu.event.type, create_pdu.event.state_key)
    end

    test "returns {:ok, latest_pdu} when more than one PDU of the given key has been sent in the room" do
      room_id = Fixtures.room_id()
      user_id = Fixtures.user_id()

      first_membership_pdu =
        room_id |> Events.membership(user_id, user_id, :join) |> Fixtures.authz_event([]) |> PDU.new!([], 0)

      %State{} = state = State.handle_pdu(State.new!(), first_membership_pdu)
      assert {:ok, ^first_membership_pdu} = State.fetch(state, "m.room.member", user_id)

      second_membership_pdu =
        room_id
        |> Events.membership(user_id, user_id, :join)
        |> Fixtures.authz_event([])
        |> PDU.new!([first_membership_pdu.event.id], 1)

      %State{} = state = State.handle_pdu(state, second_membership_pdu)

      assert {:ok, ^second_membership_pdu} = State.fetch(state, "m.room.member", user_id)
    end
  end

  describe "fetch_at/3,4" do
    test "returns {:error, :not_found} when no state event of the given key has been sent in the room" do
      create_pdu = Fixtures.authz_create_event() |> PDU.new!([], 0)
      %State{} = state = State.handle_pdu(State.new!(), create_pdu)

      assert {:error, :not_found} = State.fetch_at(state, "m.room.join_rules", create_pdu)
      assert {:error, :not_found} = State.fetch_at(state, "m.room.join_rules", "", create_pdu)
    end

    test "returns {:ok, given_pdu} when one PDU of the given key has been sent in the room" do
      create_pdu = Fixtures.authz_create_event() |> PDU.new!([], 0)

      %State{} = state = State.new!()
      assert {:error, :not_found} = State.fetch_at(state, "m.room.create", create_pdu)
      %State{} = state = State.handle_pdu(state, create_pdu)
      assert {:ok, ^create_pdu} = State.fetch_at(state, "m.room.create", create_pdu)
    end

    test "returns {:ok, given_pdu} when more than one PDU of the given key has been sent in the room" do
      room_id = Fixtures.room_id()
      user_id = Fixtures.user_id()

      first_membership_pdu =
        room_id |> Events.membership(user_id, user_id, :join) |> Fixtures.authz_event([]) |> PDU.new!([], 0)

      message_pdu =
        Fixtures.authz_message_event(room_id, user_id, [first_membership_pdu.event.id], "hello world")
        |> PDU.new!([first_membership_pdu.event.id], 1)

      second_membership_pdu =
        room_id
        |> Events.membership(user_id, user_id, :join)
        |> Fixtures.authz_event([first_membership_pdu.event.id])
        |> PDU.new!([message_pdu.event.id], 2)

      %State{} =
        state =
        State.new!()
        |> State.handle_pdu(first_membership_pdu)
        |> State.handle_pdu(message_pdu)
        |> State.handle_pdu(second_membership_pdu)

      assert {:ok, ^first_membership_pdu} = State.fetch_at(state, "m.room.member", user_id, first_membership_pdu)
      assert {:ok, ^first_membership_pdu} = State.fetch_at(state, "m.room.member", user_id, message_pdu)
      assert {:ok, ^second_membership_pdu} = State.fetch_at(state, "m.room.member", user_id, second_membership_pdu)
    end
  end

  describe "authorize_event/2" do
    setup do
      user_id = Fixtures.user_id()
      room_id = Fixtures.room_id()
      room_version = "11"

      init_state_events =
        Stream.concat(
          [
            Events.create(room_id, user_id, room_version, %{}),
            Events.membership(room_id, user_id, user_id, :join),
            Events.power_levels(room_id, user_id, %{})
          ],
          Events.from_preset(:public_chat, room_id, user_id)
        )

      %{user_id: user_id, room_id: room_id, room_version: room_version, init_state_events_stream: init_state_events}
    end

    test "authorizes the core new-room state events", %{init_state_events_stream: init_state_events} do
      assert_events_apply(init_state_events)
    end

    test "authorizes additional message/state events from the creator", %{
      user_id: user_id,
      room_id: room_id,
      init_state_events_stream: init_state_events
    } do
      init_state_events
      |> Stream.concat(Stream.map(["testing", "okay this works"], &Events.text_message(room_id, user_id, &1)))
      |> Stream.concat([Events.name(room_id, user_id, "My Room"), Events.topic(room_id, user_id, "It's just my room")])
      |> assert_events_apply()
    end

    test "does not authorize new message/state events from a user not in the room", %{
      room_id: room_id,
      init_state_events_stream: init_state_events
    } do
      random_user_id = Fixtures.user_id()

      %{state: state} = assert_events_apply(init_state_events)

      assert {:error, :unauthorized} =
               State.authorize_event(state, Events.text_message(room_id, random_user_id, "hi :)"))

      assert {:error, :unauthorized} =
               State.authorize_event(state, Events.name(room_id, random_user_id, "This is my room now"))
    end

    test "does not authorize new message/state events from a user no longer in the room", %{
      user_id: user_id,
      room_id: room_id,
      init_state_events_stream: init_state_events
    } do
      random_user_id = Fixtures.user_id()

      %{state: state} =
        init_state_events
        |> Stream.concat([
          Events.membership(room_id, user_id, random_user_id, :invite),
          Events.membership(room_id, random_user_id, random_user_id, :join),
          Events.text_message(room_id, random_user_id, "hi :)"),
          Events.power_levels(room_id, user_id, %{"users" => %{user_id => 100, random_user_id => 50}}),
          Events.text_message(room_id, user_id, "you are now my mod"),
          Events.name(room_id, random_user_id, "This is my room now"),
          Events.membership(room_id, user_id, random_user_id, :leave, "ok nvm get out of here"),
          Events.name(room_id, user_id, "My Room")
        ])
        |> assert_events_apply()

      assert {:error, :unauthorized} =
               State.authorize_event(state, Events.text_message(room_id, random_user_id, "LET ME INNNNNNN"))

      assert {:error, :unauthorized} =
               State.authorize_event(state, Events.name(room_id, random_user_id, "IT WAS SUPPOSED TO BE MINE"))
    end
  end

  defp assert_events_apply(events) do
    Enum.reduce(events, %{stream_num: 0, prev_event_ids: [], state: State.new!()}, fn
      %{"type" => type, "content" => content, "sender" => sender} = event_attrs, acc ->
        assert {:ok, %AuthorizedEvent{type: ^type, content: ^content, sender: ^sender} = event} =
                 State.authorize_event(acc.state, event_attrs)

        expected_state_key =
          case Map.fetch(event_attrs, "state_key") do
            :error -> :none
            {:ok, state_key} when is_binary(state_key) -> state_key
          end

        assert ^expected_state_key = event.state_key

        state = State.handle_pdu(acc.state, PDU.new!(event, acc.prev_event_ids, acc.stream_num))

        acc
        |> Map.put(:state, state)
        |> Map.put(:prev_event_ids, [event.id])
        |> Map.update!(:stream_num, &(&1 + 1))
    end)
  end
end
