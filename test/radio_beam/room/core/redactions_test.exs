defmodule RadioBeam.Room.Core.RedactionsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Core.Redactions
  alias RadioBeam.Room.DAG
  alias RadioBeam.Room.Events

  describe "Core.send/3 (Core.Redactions.apply_or_queue/2)" do
    setup do
      user_id = Fixtures.user_id()
      %{room: Room.Core.new("11", user_id, default_deps()), creator_id: user_id}
    end

    test "applies a redaction to an event when we have it on the room DAG", %{room: room, creator_id: creator_id} do
      msg_event = Events.text_message(room.id, creator_id, "afsjdghk")
      {:sent, room, %{event: %{id: to_redact_id}}} = Room.Core.send(room, msg_event, default_deps())

      redaction_event = Events.redaction(room.id, creator_id, to_redact_id, "cat walked on keyboard")
      {:sent, room, _pdu} = Room.Core.send(room, redaction_event, default_deps())

      assert 0 = map_size(room.redactions.pending)
      pdu = DAG.fetch!(room.dag, to_redact_id)
      assert 0 = map_size(pdu.event.content)
    end

    test "queues a redaction as pending when we don't yet have the target event on the room DAG", %{
      room: room,
      creator_id: creator_id
    } do
      to_redact_id = "!asdf"

      redaction_event = Events.redaction(room.id, creator_id, to_redact_id, "cat walked on keyboard")
      {:sent, room, _pdu} = Room.Core.send(room, redaction_event, default_deps())

      assert 1 = map_size(room.redactions.pending)
    end
  end

  describe "Core.send/3 (Core.Redactions.apply_any_pending/2)" do
    setup do
      user_id = Fixtures.user_id()
      %{room: Room.Core.new("11", user_id, default_deps()), creator_id: user_id}
    end

    test "returns the room if no redaction is pending for the given event_id", %{room: room} do
      pdu = DAG.root!(room.dag)
      assert ^room = Redactions.apply_any_pending(room, pdu.event.id)
    end

    # TODO: can't write this test until Room.DAG supports inserting an event at
    # a particular point (as opposed to just appending it). This is required
    # since we want to simulate the target of the redaction event arriving late
    # (and thus invoking the pending-redaction-application functionality)
    @tag :skip
    test "applies a pending redaction", %{room: room, creator_id: creator_id} do
      # first create a message event and its redaction...
      msg_event = Events.text_message(room.id, creator_id, "afsjdghk")
      {:sent, stub_room, %{event: %{id: to_redact_id} = msg_event}} = Room.Core.send(room, msg_event, default_deps())

      redaction_event = Events.redaction(room.id, creator_id, to_redact_id, "cat walked on keyboard")
      {:sent, _room, %{event: redaction_event}} = Room.Core.send(stub_room, redaction_event, default_deps())

      # ...then simulate the events arriving out-of-order
      assert {:sent, room, %{}} = Room.Core.send(room, redaction_event, default_deps())
      assert 1 = map_size(room.redactions.pending)
      assert {:sent, room, %{event: %{content: content}}} = Room.Core.send(room, msg_event, default_deps())
      assert 0 = map_size(content)
      assert 0 = map_size(room.redactions.pending)
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
