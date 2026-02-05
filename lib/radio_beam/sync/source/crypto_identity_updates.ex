defmodule RadioBeam.Sync.Source.CryptoIdentityUpdates do
  @moduledoc """
  Returns user IDs who the given user shares at least one room with, and whose
  crypto identity has changed since the given `since` token. Will also return
  user IDs who the user no longer shares a room with since the given token.
  """
  @behaviour RadioBeam.Sync.Source

  alias RadioBeam.PubSub
  alias RadioBeam.Sync.NextBatch
  alias RadioBeam.Sync.Source
  alias RadioBeam.User.KeyStore

  @impl Source
  def top_level_path(_key, _), do: ["device_lists"]

  @impl Source
  def inputs, do: [:user_id, :full_last_batch]

  @impl Source
  def run(inputs, key, sink_pid) do
    user_id = inputs.user_id

    batch =
      case Map.get(inputs, :full_last_batch) do
        nil -> NextBatch.new!(1)
        full_last_batch -> full_last_batch
      end

    PubSub.subscribe(PubSub.user_membership_or_crypto_id_changed())

    empty = MapSet.new()

    case KeyStore.all_changed_since(user_id, &NextBatch.fetch(batch, &1), NextBatch.timestamp(batch)) do
      %{changed: ^empty, left: ^empty} ->
        Source.notify_waiting(sink_pid, key)

        receive do
          :crypto_id_changed -> run(inputs, key, sink_pid)
        end

      update_map ->
        {:ok, update_map |> Map.update!(:changed, &MapSet.to_list/1) |> Map.update!(:left, &MapSet.to_list/1), nil}
    end
  end
end
