defmodule RadioBeam.Room.Timeline.ChunkTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.Room.EventGraph.PaginationToken
  alias RadioBeam.User.EventFilter
  alias RadioBeam.Room.Timeline.Chunk

  defp get_known_memberships, do: []

  setup do
    user = Fixtures.user()
    {:ok, room_id} = Room.create(user)
    {:ok, room} = RadioBeam.Repo.fetch(Room, room_id)
    Fixtures.send_text_msg(room_id, user.id, "hellloooo")
    %{user: user, room: room}
  end

  describe "new/7" do
    test "creates a new %Timeline.Chunk{} with the expected state events", %{room: room, user: %{id: user_id}} do
      {:ok, pdu_stream, :root} = EventGraph.traverse(room.id, :tip)
      timeline_events = Enum.to_list(pdu_stream)

      filter = EventFilter.new(%{})

      chunk = Chunk.new(room, timeline_events, :backward, :tip, :no_more_events, &get_known_memberships/0, filter)

      tip_event_id = hd(timeline_events).event_id

      assert %Chunk{
               timeline_events: ^timeline_events,
               state_events: [%{type: "m.room.member", state_key: ^user_id}],
               start: %PaginationToken{event_ids: [^tip_event_id]},
               next_page: :no_more_events,
               room_version: "11",
               filter: ^filter
             } = chunk
    end
  end

  describe "Jason.Encoder implementation encodes a suitable response for the C-S spec /messages API" do
    test "for a complete %Chunk{}", %{room: room} do
      {:ok, pdu_stream, :root} = EventGraph.traverse(room.id, :tip)
      timeline_events = Enum.to_list(pdu_stream)

      filter = EventFilter.new(%{})

      chunk = Chunk.new(room, timeline_events, :backward, :tip, :no_more_events, &get_known_memberships/0, filter)

      assert {:ok, json} = Jason.encode(chunk)
      assert json =~ ~s|"chunk":[|
      assert json =~ ~s|"state":[|
      assert json =~ ~s|"start":"batch:|
      refute json =~ ~s|"end":|

      decoded_response = Jason.decode!(json)
      assert 3 = map_size(decoded_response)
      assert 1 = length(decoded_response["state"])
      assert 7 = length(decoded_response["chunk"])
    end

    test "for a partial %Chunk{}", %{room: room} do
      {:ok, pdu_stream, :root} = EventGraph.traverse(room.id, :tip)
      timeline_events = Enum.take(pdu_stream, 6)

      filter = EventFilter.new(%{})

      end_token = timeline_events |> hd() |> PaginationToken.new(:backward)

      chunk = Chunk.new(room, timeline_events, :backward, :tip, end_token, &get_known_memberships/0, filter)

      assert {:ok, json} = Jason.encode(chunk)
      assert json =~ ~s|"chunk":[|
      assert json =~ ~s|"state":[|
      assert json =~ ~s|"start":"batch:|
      assert json =~ ~s|"end":"batch:|

      decoded_response = Jason.decode!(json)
      assert 4 = map_size(decoded_response)
      assert 1 = length(decoded_response["state"])
      assert 6 = length(decoded_response["chunk"])
    end
  end
end
