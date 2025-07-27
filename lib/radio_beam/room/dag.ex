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

  def append!(%__MODULE__{} = dag, %AuthorizedEvent{} = event) do
    %PDU{} = pdu = PDU.new!(event, dag.forward_extremities, dag.next_stream_number)

    struct!(dag,
      pdu_map: Map.put(dag.pdu_map, event.id, pdu),
      forward_extremities: [event.id],
      next_stream_number: dag.next_stream_number + 1
    )
  end

  def redact(%__MODULE__{} = dag, _event_id) do
    # TODO
    dag
  end
end
