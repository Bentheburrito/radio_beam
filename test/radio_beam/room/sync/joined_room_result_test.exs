defmodule RadioBeam.Room.Sync.JoinedRoomResultTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.EventGraph
  alias RadioBeam.Room
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.User.EventFilter

  defp event_ids_to_pdus(event_ids) do
    {:ok, pdus} = RadioBeam.Repo.get_all(RadioBeam.PDU, event_ids)
    pdus
  end

  describe "new/11" do
    setup do
      user = Fixtures.user()
      room = Fixtures.room("11", user.id)
      Fixtures.send_room_msg(room, user.id, "hellloooo")
      {user, device} = Fixtures.device(user)
      %{user: user, device: device, room: room}
    end

    test "returns a JoinedRoomResult of the expected shape when its given a non-empty timeline", %{
      user: user,
      device: device,
      room: room
    } do
      timeline_events =
        Room.View.Core.Timeline
        |> Fixtures.make_room_view(room)
        |> Room.View.Core.Timeline.topological_stream(user.id, :root, &Room.DAG.fetch!(room.dag, &1))
        |> Enum.to_list()

      room_sync = Room.Sync.init(user, device.id, get_room_ids_to_sync: fn _ -> [room.id] end)

      %JoinedRoomResult{} =
        joined_room_result = JoinedRoomResult.new(room_sync, room, timeline_events, :no_more_events, :initial, "join")

      assert joined_room_result.timeline_events == Enum.reverse(timeline_events)
      assert %{type: "m.room.create"} = List.first(joined_room_result.timeline_events)
      assert %{type: "m.room.message"} = List.last(joined_room_result.timeline_events)
      assert 0 = joined_room_result.state_events |> Enum.to_list() |> length()
      assert :no_earlier_events = joined_room_result.maybe_next_order_id
    end

    test "returns :no_update when given an empty timeline", %{user: user, device: device, room: room} do
      room_sync = Room.Sync.init(user, device.id, get_room_ids_to_sync: fn _ -> [room.id] end)
      state_pdus = room.state |> Room.State.get_all() |> Map.values()

      assert :no_update = JoinedRoomResult.new(room_sync, room, [], :no_more_events, state_pdus, "join")
    end
  end

  describe "Jason.Encoder implementation" do
    test "encodes an JoinedRoomResult as expected by the C-S spec" do
      user = Fixtures.user()
      {user, device} = Fixtures.device(user)
      room = Fixtures.room("11", user.id)
      Fixtures.send_room_msg(room, user.id, "helloooooooo")

      timeline_events =
        Room.View.Core.Timeline
        |> Fixtures.make_room_view(room)
        |> Room.View.Core.Timeline.topological_stream(user.id, :root, &Room.DAG.fetch!(room.dag, &1))
        |> Enum.to_list()

      room_sync = Room.Sync.init(user, device.id, get_room_ids_to_sync: fn _ -> [room.id] end)

      %JoinedRoomResult{} =
        joined_room_result =
        JoinedRoomResult.new(
          room_sync,
          room,
          timeline_events,
          :no_more_events,
          :initial,
          "join"
        )

      assert {:ok, json} = Jason.encode(joined_room_result)
      assert json =~ ~s|"state":{"events":[]|
      assert json =~ ~s|"type":"m.room.create"|
      assert json =~ ~s|"type":"m.room.join_rules"|
      assert json =~ ~s|"type":"m.room.history_visibility"|
      assert json =~ ~s|"type":"m.room.member"|
      assert json =~ ~s|"type":"m.room.message"|
    end
  end
end
