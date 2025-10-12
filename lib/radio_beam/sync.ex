defmodule RadioBeam.Sync do
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.User
  alias RadioBeam.User.Device
  alias RadioBeam.User.Keys

  require Logger

  @derive Jason.Encoder
  defstruct ~w|account_data device_lists device_one_time_keys_count device_unused_fallback_key_types next_batch rooms to_device|a

  def perform_v2(user_id, device_id, opts) do
    since_or_nil = Keyword.get(opts, :since)

    Repo.transaction!(fn ->
      with {:ok, user} <- Repo.fetch(User, user_id) do
        room_sync_result =
          user
          |> Room.Sync.init(device_id, opts)
          |> Room.Sync.perform()

        next_batch = PaginationToken.new(room_sync_result.next_batch_map, :forward, System.os_time(:millisecond))

        %__MODULE__{rooms: room_sync_result, next_batch: next_batch, to_device: %{}}
        |> put_account_data(user)
        |> put_to_device_messages(user.id, device_id, since_or_nil)
        |> put_device_key_changes(user, since_or_nil)
        |> put_device_otk_usages(user, device_id)
      end
    end)
  end

  defp put_account_data(sync, user), do: put_in(sync.account_data, Map.get(user.account_data, :global, %{}))

  defp put_to_device_messages(sync, user_id, device_id, mark_as_read) do
    case Device.Message.take_unsent(user_id, device_id, sync.next_batch, mark_as_read) do
      {:ok, unsent_messages} ->
        put_in(sync.to_device[:events], unsent_messages)

      :none ->
        sync

      error ->
        Logger.error("error when fetching unsent device messages: #{inspect(error)}")
        sync
    end
  end

  defp put_device_key_changes(sync, _user, nil), do: sync

  defp put_device_key_changes(sync, user, since) do
    changed_map =
      user
      |> Keys.all_changed_since(since)
      |> Map.update!(:changed, &MapSet.to_list/1)
      |> Map.update!(:left, &MapSet.to_list/1)

    put_in(sync.device_lists, changed_map)
  end

  defp put_device_otk_usages(sync, user, device_id) do
    {:ok, device} = User.get_device(user, device_id)

    sync =
      case Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring) do
        counts when map_size(counts) > 0 -> put_in(sync.device_one_time_keys_count, counts)
        _else -> sync
      end

    unused_fallback_algos =
      Map.keys(device.one_time_key_ring.fallback_keys) -- MapSet.to_list(device.one_time_key_ring.used_fallback_algos)

    put_in(sync.device_unused_fallback_key_types, unused_fallback_algos)
  end
end
