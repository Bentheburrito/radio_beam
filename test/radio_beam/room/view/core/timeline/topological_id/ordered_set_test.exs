defmodule RadioBeam.Room.View.Core.Timeline.TopologicalID.OrderedSetTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.DAG
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID.OrderedSet

  setup do
    creator = Fixtures.create_account()
    room = Fixtures.room("11", creator.user_id)
    %{room: room}
  end

  describe "put/2" do
    test "puts new TopologicalIDs into the set", %{room: room} do
      set = OrderedSet.new!()
      assert is_nil(OrderedSet.first(set))
      assert is_nil(OrderedSet.last(set))

      root = DAG.root!(room.dag)
      root_topo_id = TopologicalID.new!(root, [])
      set = OrderedSet.put(set, root_topo_id)

      assert ^root_topo_id = OrderedSet.first(set)
      assert ^root_topo_id = OrderedSet.last(set)

      [latest_pdu_event_id] = DAG.forward_extremities(room.dag)
      latest_pdu = DAG.fetch!(room.dag, latest_pdu_event_id)
      latest_pdu_topo_id = TopologicalID.new!(latest_pdu, [])
      set = OrderedSet.put(set, latest_pdu_topo_id)

      assert ^root_topo_id = OrderedSet.first(set)
      assert ^latest_pdu_topo_id = OrderedSet.last(set)
    end
  end

  describe "stream_from/3" do
    setup do
      creator = Fixtures.create_account()
      room = Fixtures.room("11", creator.user_id)
      %{set: ordered_set_size_five(room)}
    end

    test "streams :forward from the first ID", %{set: %OrderedSet{} = set} do
      first = OrderedSet.first(set)
      assert [^first | _rest] = list = set |> OrderedSet.stream_from(first, :forward) |> Enum.to_list()
      assert ^list = Enum.sort(list, TopologicalID)
    end

    test "streams :backward from the last ID", %{set: %OrderedSet{} = set} do
      last = OrderedSet.last(set)
      assert [^last | _rest] = list = set |> OrderedSet.stream_from(last, :backward) |> Enum.to_list()
      assert ^list = Enum.sort(list, {:desc, TopologicalID})
    end

    test "streams from arbitrary IDs", %{set: %OrderedSet{} = set} do
      first = OrderedSet.first(set)

      assert [^first, _second, _third, fourth | _rest] =
               full_list = set |> OrderedSet.stream_from(first, :forward) |> Enum.to_list()

      assert [^fourth | _rest] = forward_list = set |> OrderedSet.stream_from(fourth, :forward) |> Enum.to_list()
      assert [^fourth | backward_list] = set |> OrderedSet.stream_from(fourth, :backward) |> Enum.to_list()
      assert ^full_list = Enum.sort(backward_list ++ forward_list, TopologicalID)
    end
  end

  defp ordered_set_size_five(room) do
    # TODO: the depth is technically wrong here
    {DAG.forward_extremities(room.dag), []}
    |> Stream.unfold(fn
      {[], _} ->
        nil

      {[event_id], prev_topo_ids} ->
        pdu = DAG.fetch!(room.dag, event_id)
        topo_id = TopologicalID.new!(pdu, prev_topo_ids)
        {topo_id, {pdu.prev_event_ids, [topo_id]}}
    end)
    |> Enum.reduce(OrderedSet.new!(), &OrderedSet.put(&2, &1))
  end
end
