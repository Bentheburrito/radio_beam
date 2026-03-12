defmodule RadioBeam.Room.DAGTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.DAG

  for backend <- [DAG.Map] do
    @backend backend
    describe "new!/1" do
      test "creates a new DAG with the given m.room.create %AuthorizedEvent{} as its root PDU" do
        create_event = Fixtures.authz_create_event()
        %PDU{event: %{id: event_id}} = root = PDU.new!(create_event, [], 0)

        assert %@backend{} = dag = @backend.new!(create_event)

        assert ^root = @backend.root!(dag)
        assert [^event_id] = @backend.forward_extremities(dag)
        assert ^root = @backend.fetch!(dag, event_id)
      end
    end

    describe "append/2" do
      setup do
        %{room_id: room_id} = create_event = Fixtures.authz_create_event()
        %{room_id: room_id, create_event_id: create_event.id, dag: @backend.new!(create_event)}
      end

      test "adds a PDU to the @backend, making it the new forward extremity", %{room_id: room_id, dag: dag} do
        create_event_id = DAG.root!(dag).event.id

        %{id: msg_event_id} = msg_event = Fixtures.authz_message_event(room_id, create_event_id, [], "helllooooo")
        expected_msg_pdu = PDU.new!(msg_event, [create_event_id], 1)

        dag = @backend.append!(dag, msg_event)

        assert [^msg_event_id] = @backend.forward_extremities(dag)
        assert ^expected_msg_pdu = @backend.fetch!(dag, msg_event_id)

        %{id: msg_event_id2} = msg_event2 = Fixtures.authz_message_event(room_id, create_event_id, [], "hello?")
        expected_msg_pdu2 = PDU.new!(msg_event2, [msg_event_id], 2)

        dag = @backend.append!(dag, msg_event2)

        assert [^msg_event_id2] = @backend.forward_extremities(dag)
        assert ^expected_msg_pdu2 = @backend.fetch!(dag, msg_event_id2)
      end
    end
  end
end
