defmodule RadioBeam.Room.View.Core.Timeline.TopologicalID do
  @moduledoc """
  Opaque ID for an event ordered among other events.

  ## Internal

  TODO
  """
  alias RadioBeam.Room.PDU

  @attrs ~w|depth stream_number|a
  @enforce_keys @attrs
  defstruct @attrs
  @opaque t() :: %__MODULE__{}

  def new!(%PDU{} = pdu, prev_event_topo_ids) do
    depth = (prev_event_topo_ids |> Stream.map(& &1.depth) |> Enum.max(fn -> 0 end)) + 1
    %__MODULE__{depth: depth, stream_number: pdu.stream_number}
  end

  def group_key(%__MODULE__{} = tid), do: tid.depth

  def group_iterator(:forward), do: &(&1 + 1)
  def group_iterator(:backward), do: &(&1 - 1)

  def compare(%__MODULE__{} = tid, %__MODULE__{} = tid), do: :eq

  def compare(%__MODULE__{} = tid1, %__MODULE__{} = tid2) do
    if {tid1.depth, tid1.stream_number} > {tid2.depth, tid2.stream_number}, do: :gt, else: :lt
  end

  def parse_string("tid(" <> param_string) do
    with [depth_str, stream_num_str] <- String.split(param_string, ","),
         {depth, ""} <- Integer.parse(depth_str),
         {stream_num, ")" <> _} <- Integer.parse(stream_num_str) do
      {:ok, %__MODULE__{depth: depth, stream_number: stream_num}}
    else
      _ -> {:error, :invalid}
    end
  end

  def parse_string(_), do: {:error, :invalid}

  defimpl String.Chars do
    def to_string(topological_id), do: "tid(#{topological_id.depth},#{topological_id.stream_number})"
  end

  defimpl Jason.Encoder do
    def encode(topological_id, opts), do: Jason.Encode.string(to_string(topological_id), opts)
  end

  defmodule Range do
    @moduledoc """
    Represents an inclusive, continuous selection of events from one
    TopologicalID to another.
    """
    @attrs ~w|lower upper|a
    @enforce_keys @attrs
    defstruct @attrs

    alias RadioBeam.Room.View.Core.Timeline.TopologicalID

    def new!(lower, upper) do
      case TopologicalID.compare(lower, upper) in ~w|lt eq|a do
        true -> %__MODULE__{lower: lower, upper: upper}
      end
    end

    def in?(%TopologicalID{} = tid, %__MODULE__{} = range) do
      TopologicalID.compare(tid, range.lower) in ~w|gt eq|a and
        TopologicalID.compare(tid, range.upper) in ~w|lt eq|a
    end
  end

  defmodule OrderedSet do
    alias RadioBeam.Room.View.Core.Timeline.TopologicalID

    # index: %{topo_group_key => [TopologicalID.t()]}
    defstruct index: %{}, first_id: nil, last_id: nil

    def new!, do: %__MODULE__{}

    def stream_from(%__MODULE__{} = set, %TopologicalID{} = from, direction) do
      order_fxn = if direction == :forward, do: & &1, else: &Enum.reverse/1

      from
      |> TopologicalID.group_key()
      |> Stream.iterate(TopologicalID.group_iterator(direction))
      |> Stream.flat_map(&(set.index |> Map.get(&1, []) |> order_fxn.()))
    end

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
end
