defmodule RadioBeam.DAG.Map do
  @moduledoc """
  A simple Map-backed DAG
  """
  @behaviour RadioBeam.DAG

  alias RadioBeam.DAG.Vertex

  @enforce_keys ~w|root zid_keys|a
  defstruct root: nil,
            zid_keys: [],
            next_stream_number: 0,
            vertices_by_key: %{}

  @opaque t() :: %__MODULE__{}

  ### CREATE / UPDATE DAG ###

  @impl RadioBeam.DAG
  def new!(root_key, root_payload) do
    %Vertex{} = root = %Vertex{key: root_key, payload: root_payload, parents: [], stream_id: 0}

    %__MODULE__{
      root: root,
      zid_keys: [root.key],
      next_stream_number: 1,
      vertices_by_key: %{root.key => root}
    }
  end

  @impl RadioBeam.DAG
  def zid_keys(%__MODULE__{zid_keys: zids}), do: zids

  @impl RadioBeam.DAG
  def append!(%__MODULE__{} = dag, key, payload) do
    %Vertex{} = v = %Vertex{key: key, payload: payload, parents: dag.zid_keys, stream_id: dag.next_stream_number}

    struct!(dag,
      vertices_by_key: Map.put(dag.vertices_by_key, key, v),
      zid_keys: [key],
      next_stream_number: dag.next_stream_number + 1
    )
  end

  @impl RadioBeam.DAG
  def size(%__MODULE__{vertices_by_key: vertices_by_key}), do: map_size(vertices_by_key)

  @impl RadioBeam.DAG
  def root!(%__MODULE__{root: root}), do: root

  @impl RadioBeam.DAG
  def fetch(%__MODULE__{} = dag, key) do
    with :error <- Map.fetch(dag.vertices_by_key, key), do: {:error, :not_found}
  end

  @impl RadioBeam.DAG
  def fetch!(%__MODULE__{vertices_by_key: vertices_by_key}, key) when is_map_key(vertices_by_key, key),
    do: Map.fetch!(vertices_by_key, key)

  @impl RadioBeam.DAG
  def replace!(%__MODULE__{vertices_by_key: vertices_by_key} = dag, key, payload)
      when is_map_key(vertices_by_key, key),
      do: put_in(dag.vertices_by_key[key].payload, payload)
end
