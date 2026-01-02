defmodule RadioBeam.Sync do
  @moduledoc """
  Functions for performing /sync
  """
  alias RadioBeam.User.Database
  alias RadioBeam.Room
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.User
  alias RadioBeam.User.Device
  alias RadioBeam.User.KeyStore

  require Logger

  @derive JSON.Encoder
  defstruct ~w|account_data device_lists device_one_time_keys_count device_unused_fallback_key_types next_batch rooms to_device|a

  def perform_v2(user_id, device_id, opts) do
    since_or_nil = Keyword.get(opts, :since)

    with {:ok, client_config} <- Database.fetch_user_client_config(user_id) do
      room_sync_result =
        client_config
        |> Room.Sync.init(device_id, opts)
        |> Room.Sync.perform()

      next_batch = PaginationToken.new(room_sync_result.next_batch_map, :forward, System.os_time(:millisecond))

      %__MODULE__{rooms: room_sync_result, next_batch: next_batch, to_device: %{}}
      |> put_account_data(client_config)
      |> put_to_device_messages(client_config.user_id, device_id, since_or_nil)
      |> put_device_key_changes(client_config.user_id, since_or_nil)
      |> put_device_otk_usages(client_config.user_id, device_id)
    end
  end

  defp put_account_data(sync, client_config) do
    put_in(sync.account_data, Map.get(client_config.account_data, :global, %{}))
  end

  defp put_to_device_messages(sync, user_id, device_id, mark_as_read) do
    case User.get_undelivered_to_device_messages(user_id, device_id, sync.next_batch, mark_as_read) do
      {:ok, :none} ->
        sync

      {:ok, unsent_messages} ->
        put_in(sync.to_device[:events], unsent_messages)

      error ->
        Logger.error("error when fetching unsent device messages: #{inspect(error)}")
        sync
    end
  end

  defp put_device_key_changes(sync, _user_id, nil), do: put_in(sync.device_lists, %{changed: [], left: []})

  defp put_device_key_changes(sync, user_id, since) do
    changed_map =
      user_id
      |> KeyStore.all_changed_since(since)
      |> Map.update!(:changed, &MapSet.to_list/1)
      |> Map.update!(:left, &MapSet.to_list/1)

    put_in(sync.device_lists, changed_map)
  end

  defp put_device_otk_usages(sync, user_id, device_id) do
    {:ok, device} = Database.fetch_user_device(user_id, device_id)

    sync =
      case Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring) do
        counts when map_size(counts) > 0 -> put_in(sync.device_one_time_keys_count, counts)
        _else -> sync
      end

    unused_fallback_algos =
      Map.keys(device.one_time_key_ring.fallback_keys) -- MapSet.to_list(device.one_time_key_ring.used_fallback_algos)

    put_in(sync.device_unused_fallback_key_types, unused_fallback_algos)
  end

  def parse_pagination_token(maybe_encoded_pagination_token), do: PaginationToken.parse(maybe_encoded_pagination_token)

  def parse_event_id_at(maybe_encoded_pagination_token, room_id) do
    with {:ok, %PaginationToken{} = token} <- PaginationToken.parse(maybe_encoded_pagination_token) do
      PaginationToken.room_last_seen_event_id(token, room_id)
    end
  end
end
