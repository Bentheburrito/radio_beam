defmodule RadioBeam.Room.Core.RelationshipsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Events

  describe "Core.send/3 (Core.Relationships.apply_event/2)" do
    setup do
      user_id = Fixtures.user_id()
      {room, _pdus} = Room.Core.new("11", user_id, default_deps())
      %{room: room, creator_id: user_id}
    end

    test "noops relationships if the event is not related to others", %{room: room, creator_id: creator_id} do
      msg_event = Events.text_message(room.id, creator_id, "hello world")
      {:sent, room, event_id, _pdus} = Room.Core.send(room, msg_event, default_deps())
      assert is_nil(Room.Chronicle.get_relation(room.chronicle, event_id))
    end

    test "applies a m.reaction event, as long as it's not a duplicate", %{room: room, creator_id: creator_id} do
      msg_event = Events.text_message(room.id, creator_id, "hello world")
      {:sent, room, _event_id, [%{event: msg_event}]} = Room.Core.send(room, msg_event, default_deps())

      key = "👍"
      rel = %{"m.relates_to" => %{"event_id" => msg_event.id, "rel_type" => "m.annotation", "key" => key}}
      reaction_event = Events.message(room.id, creator_id, "m.reaction", rel)
      {:sent, room, reaction_event_id, _pdus} = Room.Core.send(room, reaction_event, default_deps())

      assert %{"m.reaction" => [{reaction_event_id, key, creator_id}]} ==
               Room.Chronicle.get_relation(room.chronicle, msg_event.id)

      {:error, :duplicate_annotation} = Room.Core.send(room, reaction_event, default_deps())

      key2 = "💩"
      rel = %{"m.relates_to" => %{"event_id" => msg_event.id, "rel_type" => "m.annotation", "key" => key2}}
      reaction_event = Events.message(room.id, creator_id, "m.reaction", rel)
      {:sent, room, reaction_event_id2, _pdus} = Room.Core.send(room, reaction_event, default_deps())

      assert %{"m.reaction" => [{reaction_event_id2, key2, creator_id}, {reaction_event_id, key, creator_id}]} ==
               Room.Chronicle.get_relation(room.chronicle, msg_event.id)
    end
  end

  defp default_deps do
    %{
      register_room_alias: fn _, _ -> :ok end
    }
  end
end
