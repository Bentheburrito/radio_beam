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
end
