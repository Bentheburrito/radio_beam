defmodule RadioBeam.DAG.Vertex do
  @moduledoc """
  A vertex/node on the DAG
  """

  @type key() :: term()
  @type payload() :: term()

  @type t() :: %__MODULE__{key: key(), parents: [key()], payload: payload(), stream_id: term()}

  @attrs ~w|key parents payload stream_id|a
  @enforce_keys @attrs
  defstruct @attrs
end
