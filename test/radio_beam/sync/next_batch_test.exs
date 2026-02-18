defmodule RadioBeam.Sync.NextBatchTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Sync.NextBatch

  describe "new/3,4" do
    setup do
      creator_id = Fixtures.user_id()
      room = Fixtures.room("11", creator_id)
      {:sent, room, %{event: %{id: event_id}}} = Fixtures.send_room_msg(room, creator_id, "yo")

      %{room: room, event_id: event_id}
    end

    test "creates a new %NextBatch{}", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)

      for dir <- ~w|forward backward|a do
        assert %NextBatch{} = token = NextBatch.new!(now, %{room.id => event_id}, dir)
        assert ^token = NextBatch.new!(now, %{room.id => event_id}, dir)
      end
    end

    test "errors when invalid args are given", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)

      assert_raise(FunctionClauseError, fn ->
        NextBatch.new!(now, %{room.id => event_id}, :invalid_direction)
      end)

      assert_raise(FunctionClauseError, fn ->
        NextBatch.new!(-123, %{room.id => event_id}, :forward)
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
      token = NextBatch.new!(now, %{room.id => event_id}, :forward)

      assert {:ok, ^event_id} = NextBatch.fetch(token, room.id)
    end

    test "returns {:error, :not_found} when the room ID is unknown", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)
      token = NextBatch.new!(now, %{room.id => event_id}, :forward)

      assert {:error, :not_found} = NextBatch.fetch(token, Fixtures.room_id())
    end
  end

  describe "JSON.encode!/1" do
    setup do
      creator_id = Fixtures.user_id()
      room = Fixtures.room("11", creator_id)
      {:sent, room, %{event: %{id: event_id}}} = Fixtures.send_room_msg(room, creator_id, "yo")

      %{room: room, event_id: event_id}
    end

    test "successfully encodes %NextBatch{}s", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)
      other_room_id = Fixtures.room_id()
      pairs = %{room.id => event_id, other_room_id => event_id}

      for dir <- ~w|forward backward|a do
        token = NextBatch.new!(now, pairs, dir)
        encoded_token = JSON.encode!(token)

        assert encoded_token =~ "#{dir}"
        assert encoded_token =~ "#{now}"

        assert %{} = decoded_map = URI.decode_query(encoded_token)

        for "!" <> _ = room_id <- Map.keys(decoded_map) do
          assert room_id in [room.id, other_room_id]
          assert Map.fetch!(decoded_map, room_id) == event_id
        end
      end
    end
  end

  describe "decode/1" do
    setup do
      creator_id = Fixtures.user_id()
      room = Fixtures.room("11", creator_id)
      {:sent, room, %{event: %{id: event_id}}} = Fixtures.send_room_msg(room, creator_id, "yo")

      %{room: room, event_id: event_id}
    end

    test "successfully decodes an encoded %NextBatch{}", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)
      other_room_id = Fixtures.room_id()
      pairs = %{room.id => event_id, other_room_id => event_id}

      token = NextBatch.new!(now, pairs, :forward)
      encoded_token = to_string(token)

      assert {:ok, ^token} = NextBatch.decode(encoded_token)
    end

    test "returns an error tuple for malformed batch string", %{room: room, event_id: event_id} do
      now = System.os_time(:millisecond)
      other_room_id = Fixtures.room_id()
      pairs = %{room.id => event_id, other_room_id => event_id}

      token = NextBatch.new!(now, pairs, :forward)
      malformed_token = to_string(token) <> "asdf"

      assert {:error, :malformed_batch_token} = NextBatch.decode(malformed_token)

      malformed_token = token |> to_string() |> String.replace("timestamp", "")
      assert {:error, :malformed_batch_token} = NextBatch.decode(malformed_token)
    end
  end
end
