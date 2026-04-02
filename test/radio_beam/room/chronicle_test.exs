defmodule RadioBeam.Room.ChronicleTest do
  use ExUnit.Case,
    async: true,
    parameterize:
      for(
        backend <- [RadioBeam.Room.Chronicle.Map],
        dag_backend <- [RadioBeam.DAG.Map],
        room_version <- ~w|10 11 12|,
        do: %{
          backend: backend,
          dag_backend: dag_backend,
          room_version: room_version
        }
      )

  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Chronicle
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.PDU

  setup %{backend: backend, dag_backend: dag_backend, room_version: room_version} do
    creator_id = Fixtures.user_id()
    create_event_attrs = Events.create(&Room.generate_legacy_id/0, creator_id, room_version, %{})

    chronicle = backend.new!(create_event_attrs, dag_backend)
    room_id = Chronicle.room_id(chronicle)

    init_state_events =
      Stream.concat(
        [
          Events.membership(room_id, creator_id, creator_id, :join),
          Events.power_levels(room_id, room_version, creator_id, %{})
        ],
        Events.from_preset(:public_chat, room_id, creator_id)
      )

    %{chronicle: chronicle, creator_id: creator_id, init_state_events_stream: init_state_events}
  end

  describe "new!/2" do
    test "puts a state event PDU in the mapping under {event.type, event.state_key}", %{
      chronicle: chronicle,
      creator_id: creator_id,
      room_version: room_version
    } do
      %AuthorizedEvent{id: event_id} = event = Chronicle.get_create_event(chronicle)

      %PDU{event: %{id: ^event_id}} = create_pdu = Chronicle.fetch_pdu!(chronicle, event.id)
      assert [] = create_pdu.prev_event_ids
      assert 0 = create_pdu.stream_number

      assert [] = event.auth_events
      assert %{"room_version" => ^room_version} = event.content
      assert event.origin_server_ts <= System.os_time(:millisecond)
      assert [] = event.prev_event_ids
      assert :none = event.prev_state_content
      assert ^creator_id = event.sender
      assert "" = event.state_key
      assert "m.room.create" = event.type
    end
  end

  describe "try_append/2" do
    test "appends the given valid event attrs", %{chronicle: chronicle, creator_id: creator_id} do
      room_id = Chronicle.room_id(chronicle)
      event_attrs = Events.membership(room_id, creator_id, creator_id, :join)
      %AuthorizedEvent{id: create_event_id} = Chronicle.get_create_event(chronicle)

      assert {:ok, chronicle, %AuthorizedEvent{} = event} = Chronicle.try_append(chronicle, event_attrs)
      assert %{"membership" => "join"} = event.content
      assert %{{"m.room.create", ""} => ^create_event_id} = Chronicle.get_state_mapping(chronicle)
    end

    test "appends the given valid event attrs, superceding a previous state event", %{
      chronicle: chronicle,
      creator_id: creator_id
    } do
      room_id = Chronicle.room_id(chronicle)

      creator_member_event_attrs = Events.membership(room_id, creator_id, creator_id, :join)
      name_event_attrs = Events.name(room_id, creator_id, "test")
      name_event_attrs2 = Events.name(room_id, creator_id, "My Room")

      {:ok, chronicle, _} = Chronicle.try_append(chronicle, creator_member_event_attrs)

      {:ok, chronicle, %{id: name_id1, content: %{"name" => "test"}}} =
        Chronicle.try_append(chronicle, name_event_attrs)

      {:ok, chronicle, %{id: name_id2, content: %{"name" => "My Room"}}} =
        Chronicle.try_append(chronicle, name_event_attrs2)

      assert %{{"m.room.name", ""} => ^name_id1} =
               Chronicle.get_state_mapping(chronicle, :current_state, false)

      assert %{{"m.room.name", ""} => ^name_id2} =
               Chronicle.get_state_mapping(chronicle, :current_state, true)
    end

    test "authorizes all of the core new-room state events", %{
      chronicle: chronicle,
      init_state_events_stream: init_state_events
    } do
      assert_events_apply(init_state_events, chronicle)
    end

    test "authorizes additional message/state events from the creator", %{
      chronicle: chronicle,
      creator_id: creator_id,
      init_state_events_stream: init_state_events
    } do
      room_id = Chronicle.room_id(chronicle)

      init_state_events
      |> Stream.concat(Stream.map(["testing", "okay this works"], &Events.text_message(room_id, creator_id, &1)))
      |> Stream.concat([
        Events.name(room_id, creator_id, "My Room"),
        Events.topic(room_id, creator_id, "It's just my room")
      ])
      |> assert_events_apply(chronicle)
    end

    test "does not authorize new message/state events from a user not in the room", %{
      chronicle: chronicle,
      init_state_events_stream: init_state_events
    } do
      random_user_id = Fixtures.user_id()
      room_id = Chronicle.room_id(chronicle)

      chronicle = assert_events_apply(init_state_events, chronicle)

      assert {:error, :unauthorized} =
               Chronicle.try_append(chronicle, Events.text_message(room_id, random_user_id, "hi :)"))

      assert {:error, :unauthorized} =
               Chronicle.try_append(chronicle, Events.name(room_id, random_user_id, "This is my room now"))
    end

    test "does not authorize new message/state events from a user no longer in the room", %{
      creator_id: creator_id,
      chronicle: chronicle,
      init_state_events_stream: init_state_events
    } do
      random_user_id = Fixtures.user_id()
      room_id = Chronicle.room_id(chronicle)
      room_version = Chronicle.room_version(chronicle)

      chronicle =
        init_state_events
        |> Stream.concat([
          Events.membership(room_id, creator_id, random_user_id, :invite),
          Events.membership(room_id, random_user_id, random_user_id, :join),
          Events.text_message(room_id, random_user_id, "hi :)"),
          Events.power_levels(room_id, room_version, creator_id, %{"users" => %{random_user_id => 50}}),
          Events.text_message(room_id, creator_id, "you are now my mod"),
          Events.name(room_id, random_user_id, "This is my room now"),
          Events.membership(room_id, creator_id, random_user_id, :leave, "ok nvm get out of here"),
          Events.name(room_id, creator_id, "My Room")
        ])
        |> assert_events_apply(chronicle)

      assert {:error, :unauthorized} =
               Chronicle.try_append(chronicle, Events.text_message(room_id, random_user_id, "LET ME INNNNNNN"))

      assert {:error, :unauthorized} =
               Chronicle.try_append(chronicle, Events.name(room_id, random_user_id, "IT WAS SUPPOSED TO BE MINE"))
    end
  end

  describe "fetch_event/2" do
    test "returns {:error, :not_found} when no state event of the given key has been sent in the room", %{
      chronicle: chronicle
    } do
      assert {:error, :not_found} = Chronicle.fetch_event(chronicle, "$abcde123")
    end

    test "returns {:ok, event} when one PDU of the given key has been sent in the room", %{chronicle: chronicle} do
      %AuthorizedEvent{id: create_event_id} = Chronicle.get_create_event(chronicle)

      assert {:ok, %{id: ^create_event_id}} = Chronicle.fetch_event(chronicle, create_event_id)
    end
  end

  defp assert_events_apply(events, chronicle) do
    Enum.reduce(events, chronicle, fn
      %{"type" => type, "content" => content, "sender" => sender} = event_attrs, chronicle ->
        assert {:ok, chronicle, %AuthorizedEvent{type: ^type, content: ^content, sender: ^sender, id: event_id} = event} =
                 Chronicle.try_append(chronicle, event_attrs)

        case Map.fetch(event_attrs, "state_key") do
          :error ->
            assert :none = event.state_key

          {:ok, state_key} when is_binary(state_key) ->
            assert ^state_key = event.state_key

            assert %{{^type, ^state_key} => ^event_id} =
                     Chronicle.get_state_mapping(chronicle, :current_state, true)
        end

        chronicle
    end)
  end
end
