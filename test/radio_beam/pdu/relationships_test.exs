defmodule RadioBeam.PDU.RelationshipsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.PDU.Relationships
  alias RadioBeam.Room
  alias RadioBeam.PDU

  describe "get_aggregations/3" do
    test "aggregates threaded events" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")
      {:ok, parent_pdu} = PDU.get(parent_event_id)
      assert 0 = map_size(parent_pdu.unsigned)

      relation = %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "m.thread"}}

      {:ok, thread_event_id1} = Fixtures.send_text_msg(room_id, user.id, "This is an event in a thread", relation)
      Process.sleep(5)
      {:ok, thread_event_id2} = Fixtures.send_text_msg(room_id, user.id, "This another thread msg", relation)
      Process.sleep(5)
      {:ok, thread_event_id3} = Fixtures.send_text_msg(room_id, user.id, "Yay", relation)

      {:ok, child_events} = PDU.get_children(parent_pdu)

      assert %PDU{
               unsigned: %{
                 "m.relations" => %{
                   "m.thread" => %{
                     count: 3,
                     latest_event: %{event_id: ^thread_event_id3},
                     current_user_participated: true
                   }
                 }
               }
             } =
               Relationships.get_aggregations(parent_pdu, user.id, child_events)

      assert Enum.sort(Enum.map(child_events, & &1.event_id)) ==
               Enum.sort([thread_event_id1, thread_event_id2, thread_event_id3])
    end

    test "aggregates the latest m.replace event" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")
      {:ok, parent_pdu} = PDU.get(parent_event_id)
      assert 0 = map_size(parent_pdu.unsigned)

      content = %{
        "m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "m.replace"},
        "m.new_content" => %{"body" => "This is a corrected test message", "msgtype" => "m.text"}
      }

      {:ok, _replace_event_id} = Fixtures.send_text_msg(room_id, user.id, "* This is a corrected test message", content)
      Process.sleep(5)
      {:ok, replace_event_id} = Fixtures.send_text_msg(room_id, user.id, "* This is a corrected test message", content)

      {:ok, child_events} = PDU.get_children(parent_pdu)

      assert %PDU{unsigned: %{"m.relations" => %{"m.replace" => %{event_id: ^replace_event_id}}}} =
               Relationships.get_aggregations(parent_pdu, user.id, child_events)
    end

    test "aggregates m.reference events" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")
      {:ok, parent_pdu} = PDU.get(parent_event_id)
      assert 0 = map_size(parent_pdu.unsigned)

      relation = %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "m.reference"}}

      {:ok, ref_event_id1} = Fixtures.send_text_msg(room_id, user.id, "ref event 1", relation)
      {:ok, ref_event_id2} = Fixtures.send_text_msg(room_id, user.id, "ref event 2", relation)
      {:ok, child_events} = PDU.get_children(parent_pdu)

      assert %PDU{unsigned: %{"m.relations" => %{"m.reference" => %{"chunk" => chunk}}}} =
               Relationships.get_aggregations(parent_pdu, user.id, child_events)

      assert Enum.sort(chunk) == Enum.sort([ref_event_id1, ref_event_id2])
    end

    test "does not aggregate for an unknown `rel_type`" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")
      {:ok, parent_pdu} = PDU.get(parent_event_id)
      assert 0 = map_size(parent_pdu.unsigned)

      relation = %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.what.is.this"}}

      {:ok, _ref_event_id1} = Fixtures.send_text_msg(room_id, user.id, "ref event 1", relation)
      {:ok, _ref_event_id2} = Fixtures.send_text_msg(room_id, user.id, "ref event 2", relation)
      {:ok, child_events} = PDU.get_children(parent_pdu)

      assert pdu = Relationships.get_aggregations(parent_pdu, user.id, child_events)
      assert 0 = map_size(pdu.unsigned)
    end

    test "does not add a `m.relations` property to `unsigned` if the event does is not related to an event" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")
      {:ok, parent_pdu} = PDU.get(parent_event_id)
      assert 0 = map_size(parent_pdu.unsigned)

      {:ok, child_events} = PDU.get_children(parent_pdu)

      assert pdu = Relationships.get_aggregations(parent_pdu, user.id, child_events)
      assert 0 = map_size(pdu.unsigned)
    end
  end
end
