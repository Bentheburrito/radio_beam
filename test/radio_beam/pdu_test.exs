defmodule RadioBeam.PDUTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.PDU

  describe "get_children/2" do
    test "Return an empty list when an event has no relations" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      assert Room.member?(room_id, user.id)
      {:ok, parent_pdu} = Repo.fetch(PDU, parent_event_id)
      assert {:ok, []} = EventGraph.get_children(parent_pdu)
    end

    test "Return an event's single child event" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      relation =
        %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}}

      {:ok, child_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is another msg", relation)

      assert Room.member?(room_id, user.id)
      {:ok, parent_pdu} = Repo.fetch(PDU, parent_event_id)
      assert {:ok, [%{event_id: ^child_event_id}]} = EventGraph.get_children(parent_pdu)
    end

    test "Return an event's two child events" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      relation =
        %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}}

      {:ok, child_event_id1} = Fixtures.send_text_msg(room_id, user.id, "This is another msg", relation)
      {:ok, child_event_id2} = Fixtures.send_text_msg(room_id, user.id, "And a 3rd msg", relation)

      assert Room.member?(room_id, user.id)
      {:ok, parent_pdu} = Repo.fetch(PDU, parent_event_id)

      {:ok, children} = EventGraph.get_children(parent_pdu)
      assert children |> Stream.map(& &1.event_id) |> Enum.sort() == Enum.sort([child_event_id1, child_event_id2])
      # assert {:ok, [%{event_id: ^child_event_id1}, %{event_id: ^child_event_id2}]} =
      # EventGraph.get_children(parent_pdu)
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

      assert Room.member?(room_id, user.id)
      {:ok, parent_pdu} = Repo.fetch(PDU, parent_event_id)

      assert {:ok, [%{event_id: ^child_event_id}, %{event_id: ^grandchild_event_id}]} =
               EventGraph.get_children(parent_pdu, 3)
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

      assert Room.member?(room_id, user.id)
      {:ok, parent_pdu} = Repo.fetch(PDU, parent_event_id)

      {:ok, events} = EventGraph.get_children(parent_pdu, recurse_max)
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

      assert Room.member?(room_id, user.id)
      {:ok, parent_pdu} = Repo.fetch(PDU, parent_event_id)

      {:ok, events} = EventGraph.get_children(parent_pdu, recurse_max)
      actual_ids = Enum.map(events, & &1.event_id)
      assert Enum.sort(actual_ids) == Enum.sort(expected_ids)
    end

    test "Returns an empty list when a child event is not in the same room" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, parent_event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")

      relation =
        %{"m.relates_to" => %{"event_id" => parent_event_id, "rel_type" => "org.some.random.relationship"}}

      {:ok, room_id2} = Room.create(user)
      {:ok, _child_event_id} = Fixtures.send_text_msg(room_id2, user.id, "This is another msg", relation)

      assert Room.member?(room_id, user.id)
      {:ok, parent_pdu} = Repo.fetch(PDU, parent_event_id)
      assert {:ok, []} = EventGraph.get_children(parent_pdu)
    end
  end

  test "`Access` impl behaves like a `Map`" do
    user = Fixtures.user()
    {:ok, room_id} = Room.create(user)
    {:ok, event_id} = Fixtures.send_text_msg(room_id, user.id, "This is a test message")
    {:ok, pdu} = Repo.fetch(PDU, event_id)

    assert PDU.fetch(pdu, :event_id) == Map.fetch(pdu, :event_id)
    assert PDU.get(pdu, :event_id, :default) == Map.get(pdu, :event_id, :default)
    assert PDU.get(pdu, :not_a_key, :default) == Map.get(pdu, :not_a_key, :default)
    assert PDU.pop(pdu, :event_id) == Map.pop(pdu, :event_id)
    assert PDU.get_and_update(pdu, :event_id, fn _ -> :pop end) == Map.get_and_update(pdu, :event_id, fn _ -> :pop end)
  end
end
