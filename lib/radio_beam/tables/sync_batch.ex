defmodule RadioBeam.SyncBatch do
  @moduledoc """
  A `%SyncBatch{}` maps a `since` token to a list of the latest event IDs a 
  user/client could see at the time of their last sync. 
  """
  @attrs [:batch_token, :event_ids]
  use Memento.Table,
    attributes: @attrs,
    type: :set

  def put(event_ids) do
    batch_token = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64()

    fn -> Memento.Query.write(%__MODULE__{batch_token: batch_token, event_ids: event_ids}) end
    |> Memento.transaction()
    |> case do
      {:ok, %__MODULE__{}} -> {:ok, batch_token}
      error -> error
    end
  end

  def get(batch_token) do
    Memento.transaction(fn -> Memento.Query.read(__MODULE__, batch_token) end)
  end
end
