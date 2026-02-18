defmodule RadioBeam.Sync.NextBatch do
  @moduledoc """
  Captures details about the information sent to a device in a previous call
  to /sync. This token can be given to future calls to /sync to request new
  information since the last call. These tokens can also be provided at other
  APIs (like /messages) to paginate, or otherwise scope results to
  before/after a particular point-in-time.
  """
  defstruct timestamp: 0, kvs: %{}, dir: :backward

  def new!(ts) when is_integer(ts) and ts > 0, do: %__MODULE__{timestamp: ts}
  def new!(ts, %{} = kvs) when is_integer(ts) and ts > 0, do: %__MODULE__{timestamp: ts, kvs: kvs}
  def new!(ts, kvs, dir) when dir in ~w|backward forward|a, do: ts |> new!(kvs) |> struct!(dir: dir)

  def decode(maybe_encoded_batch) do
    case URI.decode_query(maybe_encoded_batch) do
      %{"timestamp" => ts_str} = kvs ->
        case Integer.parse(ts_str) do
          {ts, ""} ->
            dir =
              case Map.get(kvs, "dir", "backward") do
                "backward" -> :backward
                "forward" -> :forward
                _ -> :backward
              end

            kvs = kvs |> Map.delete("timestamp") |> Map.delete("dir")
            {:ok, new!(ts, kvs, dir)}

          _else ->
            {:error, :malformed_batch_token}
        end

      _else ->
        {:error, :malformed_batch_token}
    end
  end

  def put(batch, _source_key, {:next_batch, k, v}), do: put_in(batch.kvs[k], v)
  def put(batch, k, v), do: put_in(batch.kvs[k], v)

  def fetch(batch, k) do
    with :error <- Map.fetch(batch.kvs, k), do: {:error, :not_found}
  end

  def timestamp(%__MODULE__{timestamp: timestamp}), do: timestamp

  def direction(%__MODULE__{dir: dir}), do: dir

  def topologically_equal?(%__MODULE__{} = nb1, %__MODULE__{} = nb2) do
    nb1.kvs == nb2.kvs and nb1.dir == nb2.dir
  end

  defimpl JSON.Encoder do
    def encode(batch, encoder) do
      batch
      |> to_string()
      |> JSON.Encoder.BitString.encode(encoder)
    end
  end

  defimpl String.Chars do
    def to_string(batch) do
      batch.kvs
      |> Map.put("timestamp", batch.timestamp)
      |> Map.put("dir", batch.dir)
      |> Stream.reject(fn {_k, v} -> is_nil(v) end)
      |> URI.encode_query()
    end
  end
end
