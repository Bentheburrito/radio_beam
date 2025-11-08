defmodule RadioBeam.Room.Events.PaginationTokenTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.Events.PaginationToken

  describe "new/3,4" do
    setup do
      creator_id = Fixtures.user_id()
      room = Fixtures.room("11", creator_id)
      {:sent, room, %{event: %{id: event_id}}} = Fixtures.send_room_msg(room, creator_id, "yo")

      %{room: room, event_id: event_id}
    end

    test "creates a new %PaginationToken{}", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)

      for dir <- ~w|forward backward|a do
        assert %PaginationToken{} = token = PaginationToken.new(%{room.id => event_id}, dir, now)
        assert ^token = PaginationToken.new(room.id, event_id, dir, now)
      end
    end

    test "errors when invalid args are given", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)

      assert_raise(FunctionClauseError, fn ->
        PaginationToken.new(room.id, event_id, :invalid_direction, now)
      end)

      assert_raise(FunctionClauseError, fn ->
        PaginationToken.new(room.id, event_id, :forward, -123)
      end)
    end
  end

  describe "room_last_seen_event_id/2" do
    setup do
      creator_id = Fixtures.user_id()
      room = Fixtures.room("11", creator_id)
      {:sent, room, %{event: %{id: event_id}}} = Fixtures.send_room_msg(room, creator_id, "yo")

      %{room: room, event_id: event_id}
    end

    test "fetches the saved event ID for the given room ID", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)
      token = PaginationToken.new(room.id, event_id, :forward, now)

      assert {:ok, ^event_id} = PaginationToken.room_last_seen_event_id(token, room.id)
    end

    test "returns {:error, :not_found} when the room ID is unknown", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)
      token = PaginationToken.new(room.id, event_id, :forward, now)

      assert {:error, :not_found} = PaginationToken.room_last_seen_event_id(token, Fixtures.room_id())
    end
  end

  describe "encode/1" do
    setup do
      creator_id = Fixtures.user_id()
      room = Fixtures.room("11", creator_id)
      {:sent, room, %{event: %{id: event_id}}} = Fixtures.send_room_msg(room, creator_id, "yo")

      %{room: room, event_id: event_id}
    end

    test "successfully encodes %PaginationToken{}s", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)
      other_room_id = Fixtures.room_id()
      pairs = %{room.id => event_id, other_room_id => event_id}

      for dir <- ~w|forward backward|a do
        prefix = "batch:#{dir}:#{now}:"
        token = PaginationToken.new(pairs, dir, now)
        encoded_token = PaginationToken.encode(token)

        assert ^prefix <> rest = encoded_token
        assert [b64_room_id, ^event_id, b64_other_room_id, ^event_id] = String.split(rest, ":")

        for b64_room_id <- [b64_room_id, b64_other_room_id] do
          assert Base.url_decode64!(b64_room_id) in [room.id, other_room_id]
        end
      end
    end
  end

  describe "parse/1" do
    setup do
      creator_id = Fixtures.user_id()
      room = Fixtures.room("11", creator_id)
      {:sent, room, %{event: %{id: event_id}}} = Fixtures.send_room_msg(room, creator_id, "yo")

      %{room: room, event_id: event_id}
    end

    test "successfully decodes an encoded %PaginationToken{}", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)
      other_room_id = Fixtures.room_id()
      pairs = %{room.id => event_id, other_room_id => event_id}

      token = PaginationToken.new(pairs, :forward, now)
      encoded_token = PaginationToken.encode(token)

      assert {:ok, ^token} = PaginationToken.parse(encoded_token)
    end
  end
end
