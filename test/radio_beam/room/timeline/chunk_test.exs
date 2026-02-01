defmodule RadioBeam.Room.Timeline.ChunkTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline.Chunk
  alias RadioBeam.Sync.Source.NextBatch
  alias RadioBeam.User.EventFilter

  defp get_known_memberships, do: []

  defp get_events_for_user(timeline, user_id, fetch_pdu!),
    do: fn event_ids -> Room.View.Core.Timeline.get_visible_events(timeline, event_ids, user_id, fetch_pdu!) end

  setup do
    account = Fixtures.create_account()
    room = Fixtures.room("11", account.user_id)
    {:sent, room, _pdu} = Fixtures.send_room_msg(room, account.user_id, "hellloooo")
    %{account: account, room: room}
  end

  describe "new/7" do
    test "creates a new %Timeline.Chunk{} with the expected state events", %{room: room, account: %{user_id: user_id}} do
      timeline = Fixtures.make_room_view(Room.View.Core.Timeline, room)
      fetch_pdu! = &Room.DAG.fetch!(room.dag, &1)

      timeline_events =
        timeline
        |> Room.View.Core.Timeline.topological_stream(user_id, :tip, fetch_pdu!)
        |> Enum.to_list()

      tip_event_id = hd(timeline_events).id
      last_event_id = List.last(timeline_events).id

      filter = EventFilter.new(%{})

      now = System.os_time(:millisecond)
      start_token = NextBatch.new!(now, %{room.id => tip_event_id}, :forward)
      end_token = NextBatch.new!(now, %{room.id => last_event_id}, :backward)

      chunk =
        Chunk.new(
          room,
          timeline_events,
          start_token,
          end_token,
          &get_known_memberships/0,
          get_events_for_user(timeline, user_id, fetch_pdu!),
          filter
        )

      assert %Chunk{
               timeline_events: ^timeline_events,
               state_events: state_event_stream,
               start: %NextBatch{} = start_token,
               end: %NextBatch{} = end_token
             } = chunk

      assert [%{type: "m.room.member", state_key: ^user_id}] = Enum.to_list(state_event_stream)

      assert {:ok, ^tip_event_id} = NextBatch.fetch(start_token, room.id)
      assert {:ok, ^last_event_id} = NextBatch.fetch(end_token, room.id)
    end
  end

  describe "JSON.Encoder implementation encodes a suitable response for the C-S spec /messages API" do
    test "for a complete %Chunk{}", %{room: room, account: %{user_id: user_id}} do
      timeline = Fixtures.make_room_view(Room.View.Core.Timeline, room)
      fetch_pdu! = &Room.DAG.fetch!(room.dag, &1)

      timeline_events =
        timeline
        |> Room.View.Core.Timeline.topological_stream(user_id, :tip, fetch_pdu!)
        |> Enum.to_list()

      tip_event_id = hd(timeline_events).id

      filter = EventFilter.new(%{})

      now = System.os_time(:millisecond)
      start_token = NextBatch.new!(now, %{room.id => tip_event_id}, :forward)

      chunk =
        Chunk.new(
          room,
          timeline_events,
          start_token,
          :no_more_events,
          &get_known_memberships/0,
          get_events_for_user(timeline, user_id, fetch_pdu!),
          filter
        )

      assert json = JSON.encode!(chunk)
      assert json =~ ~s|"chunk":[|
      assert json =~ ~s|"state":[|
      assert json =~ ~s|"start":"%21|
      refute json =~ ~s|"end":|

      decoded_response = JSON.decode!(json)
      assert 3 = map_size(decoded_response)
      assert 1 = length(decoded_response["state"])
      assert 7 = length(decoded_response["chunk"])
    end

    test "for a partial %Chunk{}", %{room: room, account: %{user_id: user_id}} do
      timeline = Fixtures.make_room_view(Room.View.Core.Timeline, room)
      fetch_pdu! = &Room.DAG.fetch!(room.dag, &1)

      timeline_events =
        timeline
        |> Room.View.Core.Timeline.topological_stream(user_id, :tip, fetch_pdu!)
        |> Enum.take(6)

      tip_event_id = hd(timeline_events).id
      last_event_id = List.last(timeline_events).id

      filter = EventFilter.new(%{})

      now = System.os_time(:millisecond)
      start_token = NextBatch.new!(now, %{room.id => tip_event_id}, :forward)
      end_token = NextBatch.new!(now, %{room.id => last_event_id}, :backward)

      chunk =
        Chunk.new(
          room,
          timeline_events,
          start_token,
          end_token,
          &get_known_memberships/0,
          get_events_for_user(timeline, user_id, fetch_pdu!),
          filter
        )

      assert json = JSON.encode!(chunk)
      assert json =~ ~s|"chunk":[|
      assert json =~ ~s|"state":[|
      assert json =~ ~s|"start":"%21|
      assert json =~ ~s|"end":"%21|

      decoded_response = JSON.decode!(json)
      assert 4 = map_size(decoded_response)
      assert 1 = length(decoded_response["state"])
      assert 6 = length(decoded_response["chunk"])
    end
  end
end
