defmodule RadioBeam.Room.DAGTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.DAG
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.AuthorizedEvent

  describe "new!/1" do
    test "creates a new %DAG{} with the given m.room.create %AuthorizedEvent{} as its root PDU" do
      create_event = Fixtures.authz_create_event()
      %PDU{event: %{id: event_id}} = root = PDU.new!(create_event, [])

      assert %DAG{root: ^root, forward_extremities: [^event_id], pdu_map: %{^event_id => ^root}} =
               DAG.new!(create_event)
    end
  end

  describe "append/2" do
    setup do
      create_event = Fixtures.authz_create_event()
      %{create_event_id: create_event.id, dag: DAG.new!(create_event)}
    end

    test "adds a PDU to the DAG, making it the new forward extremity", %{dag: %DAG{} = dag} do
      create_event_id = dag.root.event.id

      %{id: msg_event_id} = msg_event = Fixtures.authz_message_event(create_event_id, "helllooooo")
      expected_msg_pdu = PDU.new!(msg_event, [create_event_id])

      assert %DAG{pdu_map: %{^msg_event_id => ^expected_msg_pdu}, forward_extremities: [^msg_event_id]} =
               dag =
               DAG.append!(dag, msg_event)

      %{id: msg_event_id2} = msg_event2 = Fixtures.authz_message_event(create_event_id, "hello?")
      expected_msg_pdu2 = PDU.new!(msg_event2, [msg_event_id])

      assert %DAG{pdu_map: %{^msg_event_id2 => ^expected_msg_pdu2}, forward_extremities: [^msg_event_id2]} =
               DAG.append!(dag, msg_event2)
    end
  end
end
