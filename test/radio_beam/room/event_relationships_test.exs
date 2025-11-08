defmodule RadioBeam.Room.EventRelationshipsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.EventRelationships

  describe "aggregable?/1" do
    test "returns `true` for aggregable m.relates_to.rel_type values defined in the spec" do
      for rel_type <- ~w|m.thread m.replace m.reference| do
        assert EventRelationships.aggregable?(%{content: %{"m.relates_to" => %{"rel_type" => rel_type}}})
      end
    end

    test "returns `false` for non-aggregable m.relates_to.rel_type values" do
      refute EventRelationships.aggregable?(%{content: %{"m.relates_to" => %{"rel_type" => "com.some.other.type"}}})
    end
  end

  describe "get_aggregations/3" do
    test "aggregates threaded events" do
      user_id = Fixtures.user_id()
      room = Fixtures.room("11", user_id)

      {:sent, room, %{event: %{id: parent_event_id} = parent_event}} =
        Fixtures.send_room_msg(room, user_id, "This is a test message")

      assert 0 = map_size(parent_event.unsigned)

      content = %{
        "msgtype" => "m.text",
        "body" => "This is an event in a thread",
        "m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "m.thread"}
      }

      {:sent, room, %{event: %{id: thread_event_id1} = thread_event1}} =
        Fixtures.send_room_event(room, user_id, "m.room.message", content)

      {:sent, room, %{event: %{id: thread_event_id2} = thread_event2}} =
        Fixtures.send_room_event(room, user_id, "m.room.message", Map.put(content, "body", "This another thread msg"))

      {:sent, _room, %{event: %{id: thread_event_id3} = thread_event3}} =
        Fixtures.send_room_event(room, user_id, "m.room.message", Map.put(content, "body", "Yay"))

      child_events = [thread_event1, thread_event2, thread_event3]

      assert %{
               unsigned: %{
                 "m.relations" => %{
                   "m.thread" => %{
                     count: 3,
                     latest_event: %{id: ^thread_event_id3},
                     current_user_participated: true
                   }
                 }
               }
             } =
               EventRelationships.get_aggregations(parent_event, user_id, child_events)

      assert Enum.sort(Enum.map(child_events, & &1.id)) ==
               Enum.sort([thread_event_id1, thread_event_id2, thread_event_id3])
    end

    test "aggregates the latest m.replace event" do
      user_id = Fixtures.user_id()
      room = Fixtures.room("11", user_id)

      {:sent, room, %{event: parent_event}} =
        Fixtures.send_room_msg(room, user_id, "This is a test message")

      assert 0 = map_size(parent_event.unsigned)

      content = %{
        "body" => "* This is a corrected test message",
        "m.relates_to" => %{"event_id" => parent_event.id, "rel_type" => "m.replace"},
        "m.new_content" => %{"body" => "This is a corrected test message", "msgtype" => "m.text"}
      }

      {:sent, room, %{event: event1}} = Fixtures.send_room_event(room, user_id, "m.room.message", content)
      {:sent, _room, %{event: event2}} = Fixtures.send_room_event(room, user_id, "m.room.message", content)

      child_events = [event1, event2]

      expected_replace_event_id =
        if {event1.origin_server_ts, event1.id} > {event2.origin_server_ts, event2.id}, do: event1.id, else: event2.id

      assert %{unsigned: %{"m.relations" => %{"m.replace" => %{id: ^expected_replace_event_id}}}} =
               EventRelationships.get_aggregations(parent_event, user_id, child_events)
    end

    test "aggregates m.reference events" do
      user_id = Fixtures.user_id()
      room = Fixtures.room("11", user_id)

      {:sent, room, %{event: %{id: parent_event_id} = parent_event}} =
        Fixtures.send_room_msg(room, user_id, "This is a test message")

      assert 0 = map_size(parent_event.unsigned)

      content = %{
        "msgtype" => "m.text",
        "body" => "ref event 1",
        "m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "m.reference"}
      }

      {:sent, room, %{event: %{id: ref_event_id1} = event1}} =
        Fixtures.send_room_event(room, user_id, "m.room.message", content)

      {:sent, _room, %{event: %{id: ref_event_id2} = event2}} =
        Fixtures.send_room_event(room, user_id, "m.room.message", Map.put(content, "body", "ref event 2"))

      child_events = [event1, event2]

      assert %{unsigned: %{"m.relations" => %{"m.reference" => %{"chunk" => chunk}}}} =
               EventRelationships.get_aggregations(parent_event, user_id, child_events)

      assert Enum.sort(chunk) == Enum.sort([ref_event_id1, ref_event_id2])
    end

    test "does not aggregate for an unknown `rel_type`" do
      user_id = Fixtures.user_id()
      room = Fixtures.room("11", user_id)

      {:sent, room, %{event: %{id: parent_event_id} = parent_event}} =
        Fixtures.send_room_msg(room, user_id, "This is a test message")

      assert 0 = map_size(parent_event.unsigned)

      content = %{
        "msgtype" => "m.text",
        "body" => "ref event 1",
        "m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.what.is.this"}
      }

      {:sent, room, %{event: event1}} =
        Fixtures.send_room_event(room, user_id, "m.room.message", content)

      {:sent, _room, %{event: event2}} =
        Fixtures.send_room_event(room, user_id, "m.room.message", Map.put(content, "body", "ref event 2"))

      child_events = [event1, event2]

      assert event = EventRelationships.get_aggregations(parent_event, user_id, child_events)
      assert 0 = map_size(event.unsigned)
    end

    test "does not add a `m.relations` property to `unsigned` if the event is not related to an event" do
      user_id = Fixtures.user_id()
      room = Fixtures.room("11", user_id)

      {:sent, _room, %{event: parent_event}} =
        Fixtures.send_room_msg(room, user_id, "This is a test message")

      assert 0 = map_size(parent_event.unsigned)

      child_events = []

      assert event = EventRelationships.get_aggregations(parent_event, user_id, child_events)
      assert 0 = map_size(event.unsigned)
    end
  end
end
