defmodule RadioBeam.Room.Core.RelationshipsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Events

  describe "Core.send/3 (Core.Relationships.apply_event/2)" do
    setup do
      user_id = Fixtures.user_id()
      %{room: Room.Core.new("11", user_id, default_deps()), creator_id: user_id}
    end

    test "noops relationships if the event is not related to others", %{room: room, creator_id: creator_id} do
      msg_event = Events.text_message(room.id, creator_id, "hello world")
      {:sent, %{relationships: relationships}, _pdu} = Room.Core.send(room, msg_event, default_deps())
      assert relationships == room.relationships
    end

    test "applies a m.reaction event, as long as it's not a duplicate", %{room: room, creator_id: creator_id} do
      msg_event = Events.text_message(room.id, creator_id, "hello world")
      {:sent, room, %{event: msg_event}} = Room.Core.send(room, msg_event, default_deps())

      key = "👍"
      rel = %{"m.relates_to" => %{"event_id" => msg_event.id, "rel_type" => "m.annotation", "key" => key}}
      reaction_event = Events.message(room.id, creator_id, "m.reaction", rel)
      {:sent, room, %{event: %{id: reaction_event_id}}} = Room.Core.send(room, reaction_event, default_deps())

      assert [{reaction_event_id, key, creator_id}] ==
               room.relationships.children_by_event_id[msg_event.id]["m.reaction"]

      {:error, :duplicate_annotation} = Room.Core.send(room, reaction_event, default_deps())

      key2 = "💩"
      rel = %{"m.relates_to" => %{"event_id" => msg_event.id, "rel_type" => "m.annotation", "key" => key2}}
      reaction_event = Events.message(room.id, creator_id, "m.reaction", rel)
      {:sent, room, %{event: %{id: reaction_event_id2}}} = Room.Core.send(room, reaction_event, default_deps())

      assert [{reaction_event_id2, key2, creator_id}, {reaction_event_id, key, creator_id}] ==
               room.relationships.children_by_event_id[msg_event.id]["m.reaction"]
    end
  end

  defp default_deps do
    %{
      register_room_alias: fn _, _ -> :ok end
    }
  end
end
