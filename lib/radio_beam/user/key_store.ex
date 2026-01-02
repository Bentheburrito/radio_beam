defmodule RadioBeam.User.KeyStore do
  @moduledoc """
  Query a User's Device and CrossSigningKeys

  TODO: rename to User.KeyStore
  """
  import RadioBeam.AccessExtras, only: [put_nested: 3]

  alias RadioBeam.Room
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.User
  alias RadioBeam.User.CrossSigningKey
  alias RadioBeam.User.CrossSigningKeyRing
  alias RadioBeam.User.Database
  alias RadioBeam.User.Device
  alias RadioBeam.User.KeyStore.Core
  alias RadioBeam.User.RoomKeys

  require Logger

  @type put_signatures_error() ::
          :unknown_key | :disallowed_key_type | :no_master_csk | :user_not_found | CrossSigningKey.put_signature_error()

  defstruct ~w|cross_signing_key_ring last_cross_signing_change_at room_keys|a
  @type t() :: %__MODULE__{}

  def new! do
    %__MODULE__{
      cross_signing_key_ring: CrossSigningKeyRing.new(),
      last_cross_signing_change_at: 0,
      room_keys: RoomKeys.new!()
    }
  end

  ### ROOM KEYS ###

  def create_room_keys_backup(user_id, algorithm, auth_data) do
    with {:ok, %__MODULE__{} = keys} <- update_room_keys(user_id, &RoomKeys.new_backup(&1, algorithm, auth_data)),
         {:ok, %RoomKeys.Backup{} = backup} <- RoomKeys.fetch_latest_backup(keys.room_keys) do
      {:ok, backup |> RoomKeys.Backup.version() |> Integer.to_string()}
    end
  end

  def update_room_keys_backup_auth_data(user_id, version, algorithm, auth_data) do
    with {:ok, %__MODULE__{}} <- update_room_keys(user_id, &RoomKeys.update_backup(&1, version, algorithm, auth_data)) do
      :ok
    end
  end

  def fetch_backup_info(user_id, version_or_latest) do
    fetch_fxn =
      case version_or_latest do
        :latest -> &RoomKeys.fetch_latest_backup/1
        version -> &RoomKeys.fetch_backup(&1, version)
      end

    with {:ok, %__MODULE__{} = keys} <- Database.fetch_key_store(user_id),
         {:ok, %RoomKeys.Backup{} = backup} <- fetch_fxn.(keys.room_keys) do
      {:ok, RoomKeys.Backup.info_map(backup)}
    end
  end

  def fetch_room_keys_backup(user_id, version, room_id_or_all, session_id_or_all) do
    with {:ok, %__MODULE__{} = keys} <- Database.fetch_key_store(user_id),
         {:ok, %RoomKeys.Backup{} = backup} <- RoomKeys.fetch_backup(keys.room_keys, version) do
      case {room_id_or_all, session_id_or_all} do
        {:all, :all} -> {:ok, backup}
        {room_id, :all} -> backup |> RoomKeys.Backup.get(room_id) |> wrap_ok_if_not_error()
        {:all, _session_id} -> {:error, :bad_request}
        {room_id, session_id} -> backup |> RoomKeys.Backup.get(room_id, session_id) |> wrap_ok_if_not_error()
      end
    end
  end

  defp wrap_ok_if_not_error({:error, _} = error), do: error
  defp wrap_ok_if_not_error(value), do: {:ok, value}

  def put_room_keys_backup(user_id, version, backup_data) do
    with {:ok, %__MODULE__{} = keys} <- update_room_keys(user_id, &RoomKeys.put_backup_keys(&1, version, backup_data)),
         {:ok, %RoomKeys.Backup{} = backup} <- RoomKeys.fetch_backup(keys.room_keys, version) do
      {:ok, backup |> RoomKeys.Backup.info_map() |> Map.take(~w|count etag|a)}
    end
  end

  def delete_room_keys_backup(user_id, version) do
    with {:ok, %__MODULE__{}} <- update_room_keys(user_id, &RoomKeys.delete_backup(&1, version)) do
      :ok
    end
  end

  def delete_room_keys_backup(user_id, version, path_or_all) do
    with {:ok, %__MODULE__{} = keys} <-
           update_room_keys(user_id, &RoomKeys.delete_backup_keys(&1, version, path_or_all)),
         {:ok, %RoomKeys.Backup{} = backup} <- RoomKeys.fetch_backup(keys.room_keys, version) do
      {:ok, backup |> RoomKeys.Backup.info_map() |> Map.take(~w|count etag|a)}
    end
  end

  defp update_room_keys(user_id, room_keys_updater) do
    Database.update_key_store(user_id, fn %__MODULE__{} = keys ->
      case room_keys_updater.(keys.room_keys) do
        {:ok, %RoomKeys{} = room_keys} -> put_in(keys.room_keys, room_keys)
        %RoomKeys{} = room_keys -> put_in(keys.room_keys, room_keys)
        error -> error
      end
    end)
  end

  ### DEVICE KEYS / CSKs

  def claim_otks(user_device_algo_map) do
    user_device_algo_map
    |> Stream.flat_map(fn {user_id, device_algo_map} ->
      Stream.map(device_algo_map, fn {device_id, algo} -> {user_id, device_id, algo} end)
    end)
    |> Enum.reduce(%{}, fn {user_id, device_id, algo}, acc ->
      case Database.update_user_device_with(user_id, device_id, &Device.claim_otk(&1, algo)) do
        {:ok, one_time_key} -> put_nested(acc, [user_id, device_id], one_time_key)
        {:error, :not_found} -> acc
      end
    end)
  end

  def all_changed_since(user_id, %PaginationToken{} = since) do
    room_ids = Room.joined(user_id)

    membership_event_stream =
      Stream.flat_map(room_ids, fn room_id ->
        case Room.get_members(room_id, user_id, :latest_visible, &(&1 in ~w|join leave|)) do
          {:ok, member_events} -> Stream.reject(member_events, &(&1.state_key == user_id))
          _ -> []
        end
      end)

    last_seen_event_by_room_id =
      Map.new(room_ids, fn room_id ->
        with {:ok, since_event_id} <- PaginationToken.room_last_seen_event_id(since, room_id),
             {:ok, event_stream} <- Room.View.get_events(room_id, user_id, [since_event_id]),
             [since_event] <- Enum.take(event_stream, 1) do
          {room_id, since_event}
        end
      end)

    fetch_key_store = &Database.fetch_key_store/1
    get_all_devices = &Database.get_all_devices_of_user/1
    Core.all_changed_since(membership_event_stream, last_seen_event_by_room_id, since, fetch_key_store, get_all_devices)
  end

  @doc """
  Queries all local users' keys by the given map of %{user_id => [device_id]}.
  Only signatures the given `user_id` is allowed to view will be included.
  """
  @spec query_all(%{User.id() => [Device.id()]}, User.id()) :: map()
  def query_all(query_map, querying_user_id) do
    with {:ok, %__MODULE__{} = querying_user_keys} <- Database.fetch_key_store(querying_user_id) do
      Enum.reduce(query_map, %{}, fn
        {^querying_user_id, device_ids}, key_results ->
          devices = Database.get_all_devices_of_user(querying_user_id)

          Core.add_all_keys(key_results, querying_user_id, querying_user_keys, device_ids, devices)

        {target_user_id, device_ids}, key_results ->
          case Database.fetch_key_store(target_user_id) do
            {:error, :not_found} ->
              key_results

            {:ok, target_user_keys} ->
              devices = Database.get_all_devices_of_user(target_user_id)

              Core.add_allowed_keys(key_results, target_user_id, target_user_keys, device_ids, devices)
          end
      end)
    end
  end

  @spec put_signatures(User.id(), User.Device.id(), map()) ::
          :ok | {:error, %{String.t() => %{String.t() => put_signatures_error()}}}
  def put_signatures(signer_user_id, signer_device_id, user_key_map, deps \\ deps()) do
    {self_signatures, others_msk_signatures} = Map.pop(user_key_map, signer_user_id, :none)

    self_failures = Core.try_put_self_signatures(self_signatures, signer_user_id, signer_device_id, deps)
    others_failures = Core.try_put_others_msk_signatures(others_msk_signatures, signer_user_id, deps)

    case Map.merge(self_failures, others_failures) do
      failures when map_size(failures) == 0 -> :ok
      failures -> {:error, failures}
    end
  end

  defp deps do
    %{
      fetch_key_store: &Database.fetch_key_store/1,
      fetch_user_device: &Database.fetch_user_device/2,
      update_key_store: &Database.update_key_store/2,
      update_user_device_with: &Database.update_user_device_with/3
    }
  end
end
