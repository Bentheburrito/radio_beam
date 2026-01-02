defmodule RadioBeam.Room.View.Core.Timeline.TopologicalIDTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.DAG
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID

  setup do
    creator = Fixtures.create_account()
    room = Fixtures.room("11", creator.user_id)
    %{room: room}
  end

  describe "new!/2" do
    test "creates a new Topological ID from a PDU", %{room: room} do
      root = DAG.root!(room.dag)
      assert %TopologicalID{depth: 1, stream_number: 0} = root_topo_id = TopologicalID.new!(root, [])

      [latest_pdu_event_id] = DAG.forward_extremities(room.dag)
      latest_pdu = DAG.fetch!(room.dag, latest_pdu_event_id)

      assert %TopologicalID{depth: 2, stream_number: 5} = TopologicalID.new!(latest_pdu, [root_topo_id])
    end
  end

  describe "group_key/1" do
    test "returns depth as the group key", %{room: room} do
      root = DAG.root!(room.dag)
      root_topo_id = TopologicalID.new!(root, [])
      assert 1 == TopologicalID.group_key(root_topo_id)

      [latest_pdu_event_id] = DAG.forward_extremities(room.dag)
      latest_pdu = DAG.fetch!(room.dag, latest_pdu_event_id)

      latest_topo_id = TopologicalID.new!(latest_pdu, [root_topo_id])
      assert 2 = TopologicalID.group_key(latest_topo_id)
    end
  end

  describe "group_iterator/1" do
    test "maps :forward/:backward to a function to increment/decrement depth" do
      iterator = TopologicalID.group_iterator(:forward)

      for i <- 1..3 do
        assert i + 1 == iterator.(i)
      end

      iterator = TopologicalID.group_iterator(:backward)

      for i <- 1..3 do
        assert i - 1 == iterator.(i)
      end
    end
  end

  describe "parse_string/1" do
    test "parses a TopologicalID from its encoded string form" do
      encoded = "tid(1,2)"
      assert {:ok, %TopologicalID{depth: 1, stream_number: 2}} = TopologicalID.parse_string(encoded)
      encoded = "tid(0,1)"
      assert {:ok, %TopologicalID{depth: 0, stream_number: 1}} = TopologicalID.parse_string(encoded)
      encoded = "tid(156,200)"
      assert {:ok, %TopologicalID{depth: 156, stream_number: 200}} = TopologicalID.parse_string(encoded)
    end

    test "returns {:error, :invalid} when given an invalid encoded string" do
      encoded = "asdfasdf"
      assert {:error, :invalid} = TopologicalID.parse_string(encoded)
      encoded = "tid(0:1)"
      assert {:error, :invalid} = TopologicalID.parse_string(encoded)
      encoded = "(156,200)"
      assert {:error, :invalid} = TopologicalID.parse_string(encoded)
      encoded = "tid(156,200"
      assert {:error, :invalid} = TopologicalID.parse_string(encoded)
    end
  end
end
