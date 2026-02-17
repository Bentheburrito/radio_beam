defmodule RadioBeam.Room.View.Core.Timeline.TopologicalID.RangeTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.DAG
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID.Range

  setup do
    creator = Fixtures.create_account()
    room = Fixtures.room("11", creator.user_id)
    root = DAG.root!(room.dag)

    {:sent, room, pdu1} = Fixtures.send_room_msg(room, creator.user_id, "helllooooooooooo")
    {:sent, _room, pdu2} = Fixtures.send_room_msg(room, creator.user_id, "anyone there?")

    root_id = TopologicalID.new!(root, [])
    first_id = TopologicalID.new!(pdu1, [root_id])
    second_id = TopologicalID.new!(pdu2, [first_id])

    %{root: root_id, first: first_id, second: second_id}
  end

  describe "new!/2" do
    test "creates a new Range if the the first TopologicalID compares lower than the second", %{
      first: first_id,
      second: second_id
    } do
      assert %Range{} = Range.new!(first_id, second_id)
    end

    test "raises when the first TopologicalID compares higher than the second", %{first: first_id, second: second_id} do
      assert_raise CaseClauseError, fn -> Range.new!(second_id, first_id) end
    end
  end

  describe "in?" do
    test "returns true if the given TopologicalID lies in the given Range", %{
      root: root_id,
      first: first_id,
      second: second_id
    } do
      range = Range.new!(root_id, second_id)
      assert Range.in?(root_id, range)
      assert Range.in?(first_id, range)
      assert Range.in?(second_id, range)
    end

    test "returns false if the given TopologicalID lies outside the given Range", %{
      root: root_id,
      first: first_id,
      second: second_id
    } do
      range = Range.new!(first_id, second_id)
      refute Range.in?(root_id, range)

      range = Range.new!(root_id, first_id)
      refute Range.in?(second_id, range)
    end
  end
end
