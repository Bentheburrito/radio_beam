defmodule RadioBeam.PDUTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.PDU

  describe "new/2" do
    @content %{"msgtype" => "m.text", "body" => "Hello world"}

    @attrs %{
      "auth_events" => ["$somethingsomething"],
      "content" => @content,
      "depth" => 12,
      "prev_events" => ["$somethingelse"],
      "prev_state" => %{},
      "room_id" => "!room:localhost",
      "sender" => "@someone:localhost",
      "type" => "m.room.message"
    }
    test "successfully creates a Room V11 PDU" do
      assert {:ok, %PDU{content: @content}} = PDU.new(@attrs, "11")
    end

    test "errors when a required key is missing" do
      {:error, {:required_param, "type"}} = PDU.new(Map.delete(@attrs, "type"), "11")
    end
  end

  describe "get_children/3,4" do
    test "Return an empty list when an event has no relations" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      :currently_joined = Room.users_latest_join_depth(room_id, user.id)
      {:ok, parent_pdu} = PDU.get(parent_event_id)
      assert {:ok, []} = PDU.get_children(parent_pdu, user.id, :currently_joined)
    end

    test "Return an event's single child event" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      relation =
        %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}}

      {:ok, child_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is another msg", relation)

      :currently_joined = Room.users_latest_join_depth(room_id, user.id)
      {:ok, parent_pdu} = PDU.get(parent_event_id)
      assert {:ok, [%{event_id: ^child_event_id}]} = PDU.get_children(parent_pdu, user.id, :currently_joined)
    end

    test "Return an event's two child events" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      relation =
        %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}}

      {:ok, child_event_id1} = Fixtures.send_text_msg(room_id, user.id, "This is another msg", relation)
      {:ok, child_event_id2} = Fixtures.send_text_msg(room_id, user.id, "And a 3rd msg", relation)

      :currently_joined = Room.users_latest_join_depth(room_id, user.id)
      {:ok, parent_pdu} = PDU.get(parent_event_id)

      assert {:ok, [%{event_id: ^child_event_id1}, %{event_id: ^child_event_id2}]} =
               PDU.get_children(parent_pdu, user.id, :currently_joined)
    end

    test "Return an event's child and grandchild if the max_recurse level allows" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      relation =
        %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}}

      {:ok, child_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is another msg", relation)

      relation =
        %{"m.relates_to" => %{"event_id" => child_event_id, "rel_type" => "org.some.random.relationship"}}

      {:ok, grandchild_event_id} = Fixtures.send_text_msg(room_id, user.id, "And a 3rd msg", relation)

      :currently_joined = Room.users_latest_join_depth(room_id, user.id)
      {:ok, parent_pdu} = PDU.get(parent_event_id)

      assert {:ok, [%{event_id: ^child_event_id}, %{event_id: ^grandchild_event_id}]} =
               PDU.get_children(parent_pdu, user.id, :currently_joined, 3)
    end

    test "Returns an event's child and grandchildren, up until max_recurse" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      relation =
        %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}}

      {_relation, ids} =
        Enum.reduce(1..4, {relation, []}, fn _i, {relation, ids} ->
          {:ok, child_event_id} =
            Fixtures.send_text_msg(room_id, user.id, "This is the msg #{Fixtures.random_string(8)}", relation)

          {put_in(relation, ~w|m.relates_to event_id|, child_event_id), [child_event_id | ids]}
        end)

      recurse_max = 2
      expected_ids = ids |> Enum.reverse() |> Enum.take(recurse_max)

      :currently_joined = Room.users_latest_join_depth(room_id, user.id)
      {:ok, parent_pdu} = PDU.get(parent_event_id)

      {:ok, events} = PDU.get_children(parent_pdu, user.id, :currently_joined, recurse_max)
      actual_ids = Enum.map(events, & &1.event_id)
      assert Enum.sort(actual_ids) == Enum.sort(expected_ids)
    end

    test "Returns a whole tree of events (up until max_recurse)" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      relation =
        %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}}

      {:ok, child_event_id} =
        Fixtures.send_text_msg(room_id, user.id, "This is the msg #{Fixtures.random_string(8)}", relation)

      {_relation, [last_id, second_to_last_id | _] = ids} =
        Enum.reduce(1..3, {relation, [child_event_id]}, fn _i, {relation, ids} ->
          {:ok, child_event_id} =
            Fixtures.send_text_msg(room_id, user.id, "This is the msg #{Fixtures.random_string(8)}", relation)

          {put_in(relation, ~w|m.relates_to event_id|, child_event_id), [child_event_id | ids]}
        end)

      relation = put_in(relation, ~w|m.relates_to event_id|, second_to_last_id)
      {:ok, cid1} = Fixtures.send_text_msg(room_id, user.id, "This is the msg #{Fixtures.random_string(8)}", relation)
      relation = put_in(relation, ~w|m.relates_to event_id|, last_id)
      {:ok, cid2} = Fixtures.send_text_msg(room_id, user.id, "This is the msg #{Fixtures.random_string(8)}", relation)
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

      recurse_max = 3
      [_would_need_to_recurse_to_4_for_this | expected_ids] = ids

      :currently_joined = Room.users_latest_join_depth(room_id, user.id)
      {:ok, parent_pdu} = PDU.get(parent_event_id)

      {:ok, events} = PDU.get_children(parent_pdu, user.id, :currently_joined, recurse_max)
      actual_ids = Enum.map(events, & &1.event_id)
      assert Enum.sort(actual_ids) == Enum.sort(expected_ids)
    end
  end

  test "Returns an empty list when a child event is not in the same room" do
    user = Fixtures.user()
    {:ok, room_id} = Room.create(user)
    {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

    relation =
      %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}}

    {:ok, room_id2} = Room.create(user)
    {:ok, _child_event_id} = Fixtures.send_text_msg(room_id2, user.id, "This is another msg", relation)

    :currently_joined = Room.users_latest_join_depth(room_id, user.id)
    {:ok, parent_pdu} = PDU.get(parent_event_id)
    assert {:ok, []} = PDU.get_children(parent_pdu, user.id, :currently_joined)
  end
end
