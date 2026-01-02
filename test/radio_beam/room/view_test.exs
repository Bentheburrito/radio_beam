defmodule RadioBeam.Room.ViewTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room

  describe "get_child_events/3" do
    test "Return an empty list when an event has no relations" do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, parent_event_id} = Room.send_text_message(room_id, account.user_id, "This is a test message")

      assert room_id in Room.joined(account.user_id)
      assert {:ok, child_event_stream} = Room.View.get_child_events(room_id, account.user_id, parent_event_id)
      assert Enum.empty?(child_event_stream)
    end

    test "Return an event's single child event" do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, parent_event_id} = Room.send_text_message(room_id, account.user_id, "This is a test message")

      content =
        %{
          "msgtype" => "m.text",
          "body" => "This is another msg",
          "m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}
        }

      {:ok, child_event_id} = Room.send(room_id, account.user_id, "m.room.message", content)

      assert room_id in Room.joined(account.user_id)

      assert {:ok, child_event_stream} = Room.View.get_child_events(room_id, account.user_id, parent_event_id)
      assert [%{id: ^child_event_id}] = Enum.to_list(child_event_stream)
    end

    test "Return an event's two child events" do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, parent_event_id} = Room.send_text_message(room_id, account.user_id, "This is a test message")

      content =
        %{
          "msgtype" => "m.text",
          "body" => "This is another msg",
          "m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}
        }

      {:ok, child_event_id1} = Room.send(room_id, account.user_id, "m.room.message", content)

      {:ok, child_event_id2} =
        Room.send(room_id, account.user_id, "m.room.message", Map.put(content, "body", "And a 3rd msg"))

      assert room_id in Room.joined(account.user_id)

      assert {:ok, child_event_stream} = Room.View.get_child_events(room_id, account.user_id, parent_event_id)
      assert Enum.sort([child_event_id1, child_event_id2]) == child_event_stream |> Stream.map(& &1.id) |> Enum.sort()
    end

    # TOFIX: need to reimpl recurse level to un-skip the remaining
    @tag :skip
    test "return an event's child and grandchild if the max_recurse level allows" do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, parent_event_id} = Room.send_text_message(room_id, account.user_id, "This is a test message")

      content =
        %{
          "msgtype" => "m.text",
          "body" => "This is another msg",
          "m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}
        }

      {:ok, child_event_id} = Room.send(room_id, account.user_id, "m.room.message", content)

      content =
        %{
          "msgtype" => "m.text",
          "body" => "And a 3rd msg",
          "m.relates_to" => %{"event_id" => child_event_id, "rel_type" => "org.some.random.relationship"}
        }

      {:ok, grandchild_event_id} = Room.send(room_id, account.user_id, "m.room.message", content)

      assert room_id in Room.joined(account.user_id)

      assert {:ok, child_event_stream} = Room.View.get_child_events(room_id, account.user_id, parent_event_id)

      assert Enum.sort([child_event_id, grandchild_event_id]) ==
               child_event_stream |> Stream.map(& &1.id) |> Enum.sort()
    end

    # TOFIX: need to reimpl recurse level to un-skip the remaining
    @tag :skip
    test "returns an event's child and grandchildren, up until max_recurse" do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, parent_event_id} = Room.send_text_message(room_id, account.user_id, "This is a test message")

      content =
        %{
          "msgtype" => "m.text",
          "body" => "This is the msg #{Fixtures.random_string(8)}",
          "m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}
        }

      {_relation, ids} =
        Enum.reduce(1..4, {content, []}, fn _i, {content, ids} ->
          content = Map.put(content, "body", "This is the msg #{Fixtures.random_string(8)}")
          {:ok, child_event_id} = Room.send(room_id, account.user_id, "m.room.message", content)

          {put_in(content, ~w|m.relates_to event_id|, child_event_id), [child_event_id | ids]}
        end)

      recurse_max = 2
      expected_ids = ids |> Enum.reverse() |> Enum.take(recurse_max)

      assert room_id in Room.joined(account.user_id)

      assert {:ok, child_event_stream} = Room.View.get_child_events(room_id, account.user_id, parent_event_id)
      actual_ids = Enum.map(child_event_stream, & &1.id)
      assert Enum.sort(actual_ids) == Enum.sort(expected_ids)
    end

    # TOFIX: need to reimpl recurse level to un-skip the remaining
    @tag :skip
    test "Returns a whole tree of events (up until max_recurse)" do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, parent_event_id} = Room.send_text_message(room_id, account.user_id, "This is a test message")

      content =
        %{
          "msgtype" => "m.text",
          "body" => "This is the msg #{Fixtures.random_string(8)}",
          "m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}
        }

      {:ok, child_event_id} = Room.send(room_id, account.user_id, "m.room.message", content)

      {_relation, [last_id, second_to_last_id | _] = ids} =
        Enum.reduce(1..3, {content, [child_event_id]}, fn _i, {content, ids} ->
          content = Map.put(content, "body", "This is the msg #{Fixtures.random_string(8)}")
          {:ok, child_event_id} = Room.send(room_id, account.user_id, "m.room.message", content)

          {put_in(content, ~w|m.relates_to event_id|, child_event_id), [child_event_id | ids]}
        end)

      content =
        content
        |> put_in(~w|m.relates_to event_id|, second_to_last_id)
        |> Map.put("body", "This is the msg #{Fixtures.random_string(8)}")

      {:ok, cid1} = Room.send(room_id, account.user_id, "m.room.message", content)

      content =
        content
        |> put_in(~w|m.relates_to event_id|, last_id)
        |> Map.put("body", "This is the msg #{Fixtures.random_string(8)}")

      {:ok, cid2} = Room.send(room_id, account.user_id, "m.room.message", content)
      ids = [cid2, cid1] ++ ids

      # the above will give us a relationship graph that looks like:
      #     P
      #    / \
      #   C   C
      #       |
      #       C
      #      / \
      #     C   C <- let's recurse to here, level 3
      #     |
      #     C

      _recurse_max = 3
      [_would_need_to_recurse_to_4_for_this | expected_ids] = ids

      assert room_id in Room.joined(account.user_id)

      assert {:ok, child_event_stream} = Room.View.get_child_events(room_id, account.user_id, parent_event_id)
      actual_ids = Enum.map(child_event_stream, & &1.id)
      assert Enum.sort(actual_ids) == Enum.sort(expected_ids)
    end
  end
end
