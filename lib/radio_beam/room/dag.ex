defmodule RadioBeam.Room.DAG do
  @moduledoc """
  A behaviour for linking Room events in a DAG.
  """

  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.PDU

  @type t() :: term()

  @callback new!(AuthorizedEvent.t()) :: t()
  @callback forward_extremities(t()) :: [Room.event_id()]
  @callback append!(t(), AuthorizedEvent.t()) :: t()
  @callback fetch(t(), Room.event_id()) :: {:ok, PDU.t()} | {:error, :not_found}
  @callback fetch!(t(), Room.event_id()) :: PDU.t()
  @callback replace_pdu!(t(), PDU.t()) :: t()

  @callback root!(t()) :: PDU.t()
  @callback size(t()) :: non_neg_integer()

  def forward_extremities(%dag_backend{} = dag), do: dag_backend.forward_extremities(dag)
  def append!(%dag_backend{} = dag, event), do: dag_backend.append!(dag, event)
  def fetch(%dag_backend{} = dag, event_id), do: dag_backend.fetch(dag, event_id)
  def fetch!(%dag_backend{} = dag, event_id), do: dag_backend.fetch!(dag, event_id)
  def replace_pdu!(%dag_backend{} = dag, pdu), do: dag_backend.replace_pdu!(dag, pdu)

  def root!(%dag_backend{} = dag), do: dag_backend.root!(dag)
  def size(%dag_backend{} = dag), do: dag_backend.size(dag)
end
