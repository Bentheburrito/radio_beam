defmodule RadioBeam.Room.Sync.JoinedRoomResultTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Sync.JoinedRoomResult

  describe "new/11" do
    setup do
      user = Fixtures.user()

      {:sent, room, _pdu} =
        "11"
        |> Fixtures.room(user.id)
        |> Fixtures.send_room_msg(user.id, "hellloooo")

      %{user: user, room: room}
    end

    test "returns a JoinedRoomResult of the expected shape when its given a non-empty timeline", %{
      user: user,
      room: room
    } do
      timeline = Fixtures.make_room_view(Room.View.Core.Timeline, room)

      timeline_events =
        timeline
        |> Room.View.Core.Timeline.topological_stream(user.id, :tip, &Room.DAG.fetch!(room.dag, &1))
        |> Enum.to_list()

      get_events_for_user = get_events_for_user_fxn(room, timeline, user.id)

      %JoinedRoomResult{} =
        joined_room_result = JoinedRoomResult.new(room, user, timeline_events, get_events_for_user, "join")

      assert joined_room_result.timeline_events == Enum.reverse(timeline_events)
      assert %{type: "m.room.create"} = List.first(joined_room_result.timeline_events)
      assert %{type: "m.room.message"} = List.last(joined_room_result.timeline_events)
      assert 0 = joined_room_result.state_events |> Enum.to_list() |> length()
      assert :no_more_events = joined_room_result.maybe_next_event_id
    end

    test "returns :no_update when given an empty timeline", %{user: user, room: room} do
      timeline = Fixtures.make_room_view(Room.View.Core.Timeline, room)

      get_events_for_user = get_events_for_user_fxn(room, timeline, user.id)

      state_pdus = room.state |> Room.State.get_all() |> Map.values()

      opts = [maybe_last_sync_room_state_pdus: state_pdus]

      assert :no_update = JoinedRoomResult.new(room, user, [], get_events_for_user, "join", opts)
    end
  end

  describe "JSON.Encoder implementation" do
    test "encodes an JoinedRoomResult as expected by the C-S spec" do
      user = Fixtures.user()
      {:sent, room, _pdu} = "11" |> Fixtures.room(user.id) |> Fixtures.send_room_msg(user.id, "helloooooooo")

      timeline = Fixtures.make_room_view(Room.View.Core.Timeline, room)

      timeline_events =
        timeline
        |> Room.View.Core.Timeline.topological_stream(user.id, :tip, &Room.DAG.fetch!(room.dag, &1))
        |> Enum.to_list()

      get_events_for_user = get_events_for_user_fxn(room, timeline, user.id)

      %JoinedRoomResult{} =
        joined_room_result = JoinedRoomResult.new(room, user, timeline_events, get_events_for_user, "join")

      assert json = JSON.encode!(joined_room_result)
      assert json =~ ~s|"state":{"events":[]|
      assert json =~ ~s|"type":"m.room.create"|
      assert json =~ ~s|"type":"m.room.join_rules"|
      assert json =~ ~s|"type":"m.room.history_visibility"|
      assert json =~ ~s|"type":"m.room.member"|
      assert json =~ ~s|"type":"m.room.message"|
    end
  end

  defp get_events_for_user_fxn(%{id: room_id} = room, timeline, user_id) do
    fn ^room_id, event_ids ->
      Room.View.Core.Timeline.get_visible_events(timeline, event_ids, user_id, &Room.DAG.fetch!(room.dag, &1))
    end
  end
end
