defmodule RadioBeam.Room.CoreTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.Events
  alias RadioBeam.Room
  alias RadioBeam.Room.DAG
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.State

  describe "new/1" do
    test "successfully creates a new simple %Room{}" do
      version = "11"
      creator_id = Fixtures.user_id()

      assert %Room{} = room = Room.Core.new(version, creator_id, default_deps())
      assert %PDU{event: %{type: "m.room.create"}} = DAG.root!(room.dag)
      assert 6 = DAG.size(room.dag)
      assert 6 = State.size(room.state)
    end
  end

  describe "send/3" do
    setup do
      user_id = Fixtures.user_id()
      %{room: Room.Core.new("11", user_id, default_deps()), creator_id: user_id}
    end

    test "adds the creator's m.room.message events to the DAG", %{room: room, creator_id: creator_id} do
      room =
        Enum.reduce(["test.", "ok I guess this works?"], room, fn message, room ->
          assert {:sent, room, pdu} =
                   Room.Core.send(room, Events.text_message(room.id, creator_id, message), default_deps())

          assert pdu.event.type == "m.room.message"
          assert pdu.event.sender == creator_id

          room
        end)

      assert 8 = DAG.size(room.dag)
      assert 6 = State.size(room.state)
    end

    test "adds the creator's state updates to the DAG and room state", %{room: room, creator_id: creator_id} do
      events_to_add = [
        Events.name(room.id, creator_id, "A cool room"),
        Events.topic(room.id, creator_id, "This is a really cool room"),
        Events.topic(room.id, creator_id, "This is a REALLY cool room")
      ]

      room =
        Enum.reduce(events_to_add, room, fn event, room ->
          assert {:sent, room, pdu} = Room.Core.send(room, event, default_deps())
          assert pdu.event.type == event["type"]
          assert pdu.event.sender == creator_id

          room
        end)

      assert 9 = DAG.size(room.dag)
      assert 8 = State.size(room.state)
    end

    test "m.room.canonical_alias events are accepted only if the specified aliases are valid and map to this room", %{
      room: room,
      creator_id: creator_id
    } do
      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "invalid", "localhost")
      assert {:error, :invalid_alias} = Room.Core.send(room, canonical_alias_event, default_deps())

      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "not_mapped", "localhost")
      assert {:error, :not_found} = Room.Core.send(room, canonical_alias_event, default_deps())

      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "differentroom", "localhost")
      assert {:error, :alias_room_id_mismatch} = Room.Core.send(room, canonical_alias_event, default_deps())

      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "myroom", "localhost")
      deps = put_in(default_deps().resolve_room_alias, fn _ -> {:ok, room.id} end)

      assert {:sent, _room, %{event: %{type: "m.room.canonical_alias"}}} =
               Room.Core.send(room, canonical_alias_event, deps)
    end
  end

  defp default_deps do
    %{
      resolve_room_alias: fn
        "#invalid:localhost" -> {:error, :invalid_alias}
        "#not_mapped:localhost" -> {:error, :not_found}
        _alias -> {:ok, Fixtures.room_id()}
      end
    }
  end
end
