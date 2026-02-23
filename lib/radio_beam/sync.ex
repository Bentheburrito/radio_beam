defmodule RadioBeam.Sync do
  @moduledoc """
  Functions for performing /sync
  """
  alias RadioBeam.Sync.NextBatch
  alias RadioBeam.Sync.SinkServer
  alias RadioBeam.User
  alias RadioBeam.User.KeyStore

  require Logger

  def perform_v2(user_id, device_id, opts) do
    with %{} = tl_preferences <- User.get_timeline_preferences(user_id, Keyword.get(opts, :filter, :none)) do
      opts = Enum.reduce(tl_preferences, opts, fn {k, v}, opts -> Keyword.put(opts, k, v) end)

      %{"account_data" => Map.get(tl_preferences.account_data, :global, %{})}
      |> Map.merge(SinkServer.sync_v2(user_id, device_id, opts))
      |> Map.merge(device_otk_usages(user_id, device_id))
    end
  end

  # TODO: make this a Source
  defp device_otk_usages(user_id, device_id) do
    case KeyStore.one_time_key_info(user_id, device_id) do
      {:ok, info} -> info
      _error -> %{}
    end
  end

  def parse_batch_token(maybe_encoded_pagination_token), do: NextBatch.decode(maybe_encoded_pagination_token)

  def parse_event_id_at(%NextBatch{} = batch_token, room_id), do: NextBatch.fetch(batch_token, room_id)

  def parse_event_id_at(maybe_encoded_batch, room_id) do
    with {:ok, %NextBatch{} = batch_token} <- NextBatch.decode(maybe_encoded_batch) do
      NextBatch.fetch(batch_token, room_id)
    end
  end

  def batch_token_to_latest_event_id_fetcher(%NextBatch{} = batch_token), do: &NextBatch.fetch(batch_token, &1)
  def batch_token_timestamp(%NextBatch{} = batch_token), do: NextBatch.timestamp(batch_token)

  def new_batch_token_for(room_id, event_id, dir \\ :forward) do
    :millisecond
    |> System.os_time()
    |> NextBatch.new!(%{room_id => event_id}, dir)
  end
end
