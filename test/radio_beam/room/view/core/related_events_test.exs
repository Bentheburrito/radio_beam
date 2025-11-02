defmodule RadioBeam.Room.View.Core.RelatedEventsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.View.Core.RelatedEvents

  describe "handle_pdu/3" do
    setup do
      creator_id = Fixtures.user_id()
      room = Fixtures.room("11", creator_id)

      user_id = Fixtures.user_id()

      {:sent, room, _pdu} = Fixtures.send_room_membership(room, creator_id, user_id, :invite)
      {:sent, room, _pdu} = Fixtures.send_room_membership(room, user_id, user_id, :join)

      %{room: room, creator_id: creator_id, user_id: user_id}
    end

    test "noop for unrelated events", %{room: room, creator_id: creator_id} do
      {:sent, _room, pdu} = Fixtures.send_room_msg(room, creator_id, "hello")
      related_events = RelatedEvents.new!()
      assert ^related_events = RelatedEvents.handle_pdu(related_events, room, pdu)
    end

    test "tracks related events", %{room: room, creator_id: creator_id, user_id: user_id} do
      {:sent, _room, %{event: %{id: thread_root_event_id}} = thread_root_pdu} =
        Fixtures.send_room_msg(room, creator_id, "hello")

      thread_rel = %{"event_id" => thread_root_event_id, "rel_type" => "m.thread"}

      thread_message_event_attrs =
        room.id
        |> Room.Events.text_message(user_id, "what's up")
        |> update_in(["content"], &Map.put(&1, "m.relates_to", thread_rel))

      {:sent, _room, %{event: %{id: thread_event1_id}} = thread_pdu1} =
        Room.Core.send(room, thread_message_event_attrs, %{})

      thread_message_event_attrs =
        room.id
        |> Room.Events.text_message(creator_id, "nothing much hbu")
        |> update_in(["content"], &Map.put(&1, "m.relates_to", thread_rel))

      {:sent, _room, %{event: %{id: thread_event2_id}} = thread_pdu2} =
        Room.Core.send(room, thread_message_event_attrs, %{})

      related_events =
        RelatedEvents.new!()
        |> RelatedEvents.handle_pdu(room, thread_root_pdu)
        |> RelatedEvents.handle_pdu(room, thread_pdu1)
        |> RelatedEvents.handle_pdu(room, thread_pdu2)

      assert %RelatedEvents{related_by_event_id: %{^thread_root_event_id => related_mapset}} = related_events

      assert Enum.sort([thread_event1_id, thread_event2_id]) == Enum.sort(related_mapset)
    end
  end
end
