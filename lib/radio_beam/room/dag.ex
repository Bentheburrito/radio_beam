defmodule RadioBeam.Room.DAG do
  @moduledoc """
  TODO
  """

  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.PDU

  @enforce_keys ~w|root forward_extremities|a
  defstruct root: nil,
            forward_extremities: [],
            next_stream_number: 0,
            pdu_map: %{}

  # event_id_by_event_number: %{},
  # related_child_event_ids_by_event_id: %{},
  # this needs to be some kind of index
  # event_id_by_origin_server_ts: %{}

  @opaque t() :: %__MODULE__{}

  ### CREATE / UPDATE DAG ###

  def new!(%AuthorizedEvent{type: "m.room.create"} = create_event) do
    %PDU{} = root = PDU.new!(create_event, [], 0)

    %__MODULE__{
      root: root,
      forward_extremities: [root.event.id],
      next_stream_number: 1,
      pdu_map: %{root.event.id => root}
    }
  end

  def forward_extremities(%__MODULE__{forward_extremities: fes}), do: fes

  def append!(%__MODULE__{} = dag, %AuthorizedEvent{} = event) do
    %PDU{} = pdu = PDU.new!(event, dag.forward_extremities, dag.next_stream_number)

    {
      struct!(dag,
        pdu_map: Map.put(dag.pdu_map, event.id, pdu),
        forward_extremities: [event.id],
        next_stream_number: dag.next_stream_number + 1
      ),
      pdu
    }
  end

  def size(%__MODULE__{pdu_map: pdu_map}), do: map_size(pdu_map)

  def root!(%__MODULE__{root: root}), do: root

  def fetch(%__MODULE__{} = dag, event_id) do
    with :error <- Map.fetch(dag.pdu_map, event_id), do: {:error, :not_found}
  end

  def fetch!(%__MODULE__{pdu_map: pdu_map}, event_id) when is_map_key(pdu_map, event_id),
    do: Map.fetch!(pdu_map, event_id)

  def replace_pdu!(%__MODULE__{pdu_map: pdu_map} = dag, %PDU{} = pdu) when is_map_key(pdu_map, pdu.event.id),
    do: put_in(dag.pdu_map[pdu.event.id], pdu)
end
