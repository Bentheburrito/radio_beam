defmodule RadioBeam.DAG do
  @moduledoc """
  A behaviour Room-backing DAG data structures should implement.

  Implementing data structures can be mostly general-purpose DAGs with little
  Matrix context. Though it should track additional metadata for each vertex:

  - the `stream_id` of each vertex, which indicates *when* a particular vertex
  was added to the graph in relation to every other. Since this data structure
  will always be transformed serially, a simple counter would suffice.

  # Terms

  ZID (Zero In-Degree): refers to vertices/keys that have zero incoming edges.
  """

  alias RadioBeam.DAG.Vertex

  @type t() :: term()

  @callback new!(Vertex.key(), Vertex.payload()) :: t()

  @doc """
  Returns the keys of vertices in the graph which don't currently have other
  vertices pointing to them. I.e. they are not parents of any child vertices.
  """
  @callback zid_keys(t()) :: [Vertex.key()]

  @doc """
  Creates a new Vertex under the given `key` with a `payload`. Edges should
  also be added for this vertex, pointing to vertices under the keys returned
  by `zid_keys/1`.
  """
  @callback append!(t(), Vertex.key(), Vertex.payload()) :: t()
  @callback fetch(t(), Vertex.key()) :: {:ok, Vertex.t()} | {:error, :not_found}
  @callback fetch!(t(), Vertex.key()) :: Vertex.t()
  @callback replace!(t(), Vertex.key(), Vertex.payload()) :: t()

  @callback root!(t()) :: Vertex.t()
  @callback size(t()) :: non_neg_integer()

  def zid_keys(%dag_backend{} = dag), do: dag_backend.zid_keys(dag)
  def append!(%dag_backend{} = dag, key, payload), do: dag_backend.append!(dag, key, payload)
  def fetch(%dag_backend{} = dag, key), do: dag_backend.fetch(dag, key)
  def fetch!(%dag_backend{} = dag, key), do: dag_backend.fetch!(dag, key)
  def replace!(%dag_backend{} = dag, key, payload), do: dag_backend.replace!(dag, key, payload)

  def root!(%dag_backend{} = dag), do: dag_backend.root!(dag)
  def size(%dag_backend{} = dag), do: dag_backend.size(dag)
end
