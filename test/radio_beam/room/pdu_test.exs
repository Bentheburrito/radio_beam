defmodule RadioBeam.Room.PDUTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.PDU

  describe "new!/1" do
    test "creates a new %PDU{} with the given %AuthorizedEvent{} and prev_events" do
      %{id: create_event_id} = create_event = Fixtures.authz_create_event()
      assert %PDU{event: ^create_event, prev_event_ids: []} = PDU.new!(create_event, [])

      message_event =
        Fixtures.authz_message_event(Fixtures.room_id(), Fixtures.user_id(), [create_event.id], "this is a test")

      assert %PDU{event: ^message_event, prev_event_ids: [^create_event_id]} =
               PDU.new!(message_event, [create_event_id])
    end
  end
end
