defmodule RadioBeam.Room.Timeline.SyncBatch do
  @moduledoc """
  A `%SyncBatch{}` maps a `since` token to a map of room IDs -> the latest 
  event IDs a user/client could see at the time of their last sync. 
  """
  @attrs [:token, :batch_map, :succeeds]
  use Memento.Table,
    attributes: @attrs,
    type: :set

  @opaque t() :: %__MODULE__{}

  def put(batch_map, predecessor \\ nil) do
    batch_token = "batch:#{8 |> :crypto.strong_rand_bytes() |> Base.url_encode64()}"

    fn ->
      cleanup_used(predecessor)
      Memento.Query.write(%__MODULE__{token: batch_token, batch_map: batch_map, succeeds: predecessor})
    end
    |> Memento.transaction()
    |> case do
      {:ok, %__MODULE__{}} -> {:ok, batch_token}
      error -> error
    end
  end

  @spec get(batch_token :: String.t()) :: {:ok, map() | :not_found} | {:error, any()}
  def get(batch_token) do
    Memento.transaction(fn ->
      case Memento.Query.read(__MODULE__, batch_token, lock: :write) do
        nil ->
          :not_found

        %__MODULE__{} = batch ->
          batch.batch_map
      end
    end)
  end

  # assuming it is safe to assume a given token will not be used again once
  # the client uses its successor in a follow-up sync
  defp cleanup_used(token) do
    case Memento.Query.read(__MODULE__, token) do
      %__MODULE__{} = batch -> Memento.Query.delete(__MODULE__, batch.succeeds)
      nil -> :ok
    end
  end
end
