defmodule RadioBeam.Room.Timeline.SyncBatch do
  @moduledoc """
  A `%SyncBatch{}` maps a `since` token to a map of room IDs -> the latest 
  event IDs a user/client could see at the time of their last sync. 
  """
  @attrs [:token, :batch_map, :used_at]
  use Memento.Table,
    attributes: @attrs,
    type: :set

  @type t() :: %__MODULE__{}

  def put(batch_map) do
    batch_token = "batch:#{8 |> :crypto.strong_rand_bytes() |> Base.url_encode64()}"

    fn -> Memento.Query.write(%__MODULE__{token: batch_token, batch_map: batch_map, used_at: nil}) end
    |> Memento.transaction()
    |> case do
      {:ok, %__MODULE__{}} -> {:ok, batch_token}
      error -> error
    end
  end

  @spec pop(batch_token :: String.t()) :: {:ok, t() | :not_found} | {:error, any()}
  def pop(batch_token) do
    Memento.transaction(fn ->
      case Memento.Query.read(__MODULE__, batch_token, lock: :write) do
        nil ->
          :not_found

        %__MODULE__{} = batch ->
          Memento.Query.write(%__MODULE__{batch | used_at: :os.system_time(:millisecond)})
      end
    end)
  end
end
