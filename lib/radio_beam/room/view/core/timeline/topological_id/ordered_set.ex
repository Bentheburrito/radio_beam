defmodule RadioBeam.Room.View.Core.Timeline.TopologicalID.OrderedSet do
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID

  # index: %{topo_group_key => [TopologicalID.t()]}
  defstruct index: %{}, first_id: nil, last_id: nil
  @opaque t() :: %__MODULE__{index: map(), first_id: nil | TopologicalID.t(), last_id: nil | TopologicalID.t()}

  def new!, do: %__MODULE__{}

  def stream_from(%__MODULE__{} = set, %TopologicalID{} = from, direction) do
    order_fxn = if direction == :forward, do: & &1, else: &Enum.reverse/1

    from
    |> TopologicalID.group_key()
    |> Stream.iterate(TopologicalID.group_iterator(direction))
    |> Stream.take_while(&is_map_key(set.index, &1))
    |> Stream.flat_map(&(set.index |> Map.fetch!(&1) |> order_fxn.()))
  end

  def first(%__MODULE__{first_id: first}), do: first
  def last(%__MODULE__{last_id: last}), do: last

  def put(%__MODULE__{} = set, %TopologicalID{} = topo_id) do
    first_id =
      cond do
        is_nil(set.first_id) -> topo_id
        TopologicalID.compare(set.first_id, topo_id) == :lt -> set.first_id
        :else -> topo_id
      end

    last_id =
      cond do
        is_nil(set.last_id) -> topo_id
        TopologicalID.compare(set.last_id, topo_id) == :gt -> set.last_id
        :else -> topo_id
      end

    struct!(set,
      index: Map.update(set.index, TopologicalID.group_key(topo_id), [topo_id], &put_in_list(&1, topo_id)),
      first_id: first_id,
      last_id: last_id
    )
  end

  defp put_in_list(topo_id_list, topo_id), do: put_in_list(topo_id_list, topo_id, [])

  defp put_in_list([last_topo_id], topo_id, topo_id_list_reversed) do
    # if last_topo_id comes after (is greater than) topo_id, keep it the
    # last ID in the list...
    if TopologicalID.compare(last_topo_id, topo_id) == :gt do
      Enum.reverse([last_topo_id, topo_id | topo_id_list_reversed])
    else
      # ...else it should be 2nd to last, and topo_id is the new last ID
      Enum.reverse([topo_id, last_topo_id | topo_id_list_reversed])
    end
  end

  defp put_in_list([tid1, tid2 | topo_id_list], topo_id, topo_id_list_reversed) do
    if TopologicalID.Range.in?(topo_id, TopologicalID.Range.new!(tid1, tid2)) do
      Enum.reverse(topo_id_list_reversed) ++ [tid1, topo_id, tid2 | topo_id_list]
    else
      put_in_list([tid2 | topo_id_list], topo_id, [tid1 | topo_id_list_reversed])
    end
  end
end
