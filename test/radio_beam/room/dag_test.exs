defmodule RadioBeam.Room.DAGTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.DAG

  describe "new!/1" do
    test "creates a new %DAG{} with the given m.room.create %AuthorizedEvent{} as its root PDU" do
      create_event = Fixtures.authz_create_event()
      %PDU{event: %{id: event_id}} = root = PDU.new!(create_event, [], 0)

      assert %DAG{root: ^root, forward_extremities: [^event_id], pdu_map: %{^event_id => ^root}, next_stream_number: 1} =
               DAG.new!(create_event)
    end
  end

  describe "append/2" do
    setup do
      %{room_id: room_id} = create_event = Fixtures.authz_create_event()
      %{room_id: room_id, create_event_id: create_event.id, dag: DAG.new!(create_event)}
    end

    test "adds a PDU to the DAG, making it the new forward extremity", %{room_id: room_id, dag: %DAG{} = dag} do
      create_event_id = dag.root.event.id

      %{id: msg_event_id} = msg_event = Fixtures.authz_message_event(room_id, create_event_id, [], "helllooooo")
      expected_msg_pdu = PDU.new!(msg_event, [create_event_id], 1)

      assert {%DAG{
                pdu_map: %{^msg_event_id => ^expected_msg_pdu},
                forward_extremities: [^msg_event_id],
                next_stream_number: 2
              },
              ^expected_msg_pdu} =
               dag =
               DAG.append!(dag, msg_event)

      %{id: msg_event_id2} = msg_event2 = Fixtures.authz_message_event(room_id, create_event_id, [], "hello?")
      expected_msg_pdu2 = PDU.new!(msg_event2, [msg_event_id], 2)

      assert {%DAG{
                pdu_map: %{^msg_event_id2 => ^expected_msg_pdu2},
                forward_extremities: [^msg_event_id2],
                next_stream_number: 3
              },
              ^expected_msg_pdu2} =
               DAG.append!(dag, msg_event2)
    end
  end
end
