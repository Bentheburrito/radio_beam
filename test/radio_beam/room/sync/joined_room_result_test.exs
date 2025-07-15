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
      {:ok, room_id} = Room.create(user)
      {:ok, room} = RadioBeam.Repo.fetch(Room, room_id)
      Fixtures.send_text_msg(room_id, user.id, "hellloooo")
      %{user: user, room: room}
    end

    test "returns a JoinedRoomResult of the expected shape when its given a non-empty timeline", %{
      user: user,
      room: room
    } do
      {:ok, pdu_stream, :root} = EventGraph.traverse(room.id, :tip)
      timeline_events = Enum.to_list(pdu_stream)

      %JoinedRoomResult{} =
        joined_room_result =
        JoinedRoomResult.new(
          room,
          user,
          timeline_events,
          false,
          :no_earlier_events,
          :initial,
          &event_ids_to_pdus/1,
          false,
          "join",
          %{},
          EventFilter.new(%{})
        )

      assert joined_room_result.timeline_events == Enum.reverse(timeline_events)
      assert %{type: "m.room.create"} = List.first(joined_room_result.timeline_events)
      assert %{type: "m.room.message"} = List.last(joined_room_result.timeline_events)
      assert 0 = joined_room_result.state_events |> Enum.to_list() |> length()
      assert :no_earlier_events = joined_room_result.maybe_prev_batch
    end

    test "returns :no_update when given an empty timeline", %{user: user, room: room} do
      assert :no_update =
               JoinedRoomResult.new(
                 room,
                 user,
                 [],
                 false,
                 :no_earlier_events,
                 :initial,
                 &event_ids_to_pdus/1,
                 false,
                 "join",
                 %{},
                 EventFilter.new(%{})
               )
    end
  end

  describe "Jason.Encoder implementation" do
    test "encodes an JoinedRoomResult as expected by the C-S spec" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, room} = RadioBeam.Repo.fetch(Room, room_id)

      Fixtures.send_text_msg(room_id, user.id, "helloooooooo")

      {:ok, pdu_stream, :root} = EventGraph.traverse(room.id, :tip)
      timeline_events = Enum.to_list(pdu_stream)

      %JoinedRoomResult{} =
        joined_room_result =
        JoinedRoomResult.new(
          room,
          user,
          timeline_events,
          false,
          :no_earlier_events,
          :initial,
          &event_ids_to_pdus/1,
          false,
          "join",
          %{},
          EventFilter.new(%{})
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
