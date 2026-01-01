defmodule RadioBeam.User.Keys do
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
  alias RadioBeam.User.Keys.Core
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

    with {:ok, %__MODULE__{} = keys} <- Database.fetch_keys(user_id),
         {:ok, %RoomKeys.Backup{} = backup} <- fetch_fxn.(keys.room_keys) do
      {:ok, RoomKeys.Backup.info_map(backup)}
    end
  end

  def fetch_room_keys_backup(user_id, version, room_id_or_all, session_id_or_all) do
    with {:ok, %__MODULE__{} = keys} <- Database.fetch_keys(user_id),
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
    Database.update_keys(user_id, fn %__MODULE__{} = keys ->
      case room_keys_updater.(keys.room_keys) do
        {:ok, %RoomKeys{} = room_keys} -> put_room_keys(keys, room_keys)
        %RoomKeys{} = room_keys -> put_room_keys(keys, room_keys)
        error -> error
      end
    end)
  end

  # TOOD: move to Core?
  defp put_room_keys(%__MODULE__{} = keys, %RoomKeys{} = room_keys), do: put_in(keys.room_keys, room_keys)

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

    fetch_keys = &Database.fetch_keys/1
    get_all_devices = &Database.get_all_devices_of_user/1
    Core.all_changed_since(membership_event_stream, last_seen_event_by_room_id, since, fetch_keys, get_all_devices)
  end

  @doc """
  Queries all local users' keys by the given map of %{user_id => [device_id]}.
  Only signatures the given `user_id` is allowed to view will be included.
  """
  @spec query_all(%{User.id() => [Device.id()]}, User.id()) :: map()
  def query_all(query_map, querying_user_id) do
    with {:ok, %__MODULE__{} = querying_user_keys} <- Database.fetch_keys(querying_user_id) do
      Enum.reduce(query_map, %{}, fn
        {^querying_user_id, device_ids}, key_results ->
          devices = Database.get_all_devices_of_user(querying_user_id)
          devices = if Enum.empty?(device_ids), do: devices, else: Enum.filter(devices, &(&1.id in device_ids))

          add_all_keys(key_results, querying_user_id, querying_user_keys, devices)

        {target_user_id, device_ids}, key_results ->
          case Database.fetch_keys(target_user_id) do
            {:error, :not_found} ->
              key_results

            {:ok, target_user_keys} ->
              devices = Database.get_all_devices_of_user(target_user_id)
              devices = if Enum.empty?(device_ids), do: devices, else: Enum.filter(devices, &(&1.id in device_ids))

              add_allowed_keys(key_results, target_user_id, target_user_keys, devices)
          end
      end)
    end
  end

  defp add_all_keys(key_results, querying_user_id, querying_user_keys, devices) do
    user_signing_key = querying_user_keys.cross_signing_key_ring.user

    key_results
    |> add_allowed_keys(querying_user_id, querying_user_keys, devices)
    |> add_csk(["user_signing_keys", querying_user_id], user_signing_key, querying_user_id)
  end

  defp add_allowed_keys(key_results, user_id, user_keys, devices) do
    key_results
    |> add_csk(["master_keys", user_id], user_keys.cross_signing_key_ring.master, user_id)
    |> add_csk(["self_signing_keys", user_id], user_keys.cross_signing_key_ring.self, user_id)
    |> add_device_keys(user_id, devices)
  end

  defp add_csk(key_results, _path, nil, _user_id), do: key_results

  defp add_csk(key_results, path, %CrossSigningKey{} = key, user_id) do
    RadioBeam.AccessExtras.put_nested(key_results, path, CrossSigningKey.to_map(key, user_id))
  end

  defp add_device_keys(key_results, user_id, devices) do
    for %{id: device_id} = device <- devices, reduce: key_results do
      key_results ->
        RadioBeam.AccessExtras.put_nested(key_results, ["device_keys", user_id, device_id], device.identity_keys)
    end
  end

  @spec put_signatures(User.id(), User.Device.id(), map()) ::
          :ok | {:error, %{String.t() => %{String.t() => put_signatures_error()}}}
  def put_signatures(signer_user_id, signer_device_id, user_key_map) do
    {self_signatures, others_msk_signatures} = Map.pop(user_key_map, signer_user_id, :none)

    self_failures = try_put_self_signatures(self_signatures, signer_user_id, signer_device_id)
    others_failures = try_put_others_msk_signatures(others_msk_signatures, signer_user_id)

    case Map.merge(self_failures, others_failures) do
      failures when map_size(failures) == 0 -> :ok
      failures -> {:error, failures}
    end
  end

  defp try_put_self_signatures(:none, _signer_user_id, _signer_device_id), do: %{}

  defp try_put_self_signatures(self_signatures, signer_user_id, signer_device_id) do
    self_signatures
    |> Stream.map(fn {key_id_or_device_id, key_params} ->
      case try_update_device_with_signatures(signer_user_id, key_id_or_device_id, key_params) do
        # it's either a CSK key ID or an unknown key ID
        {:error, :not_found} ->
          case try_update_csk_with_signatures(signer_user_id, signer_device_id, key_id_or_device_id, key_params) do
            {:error, error} -> {:error, key_id_or_device_id, error}
            {:ok, _updated_keys} -> :ok
          end

        {:error, error} ->
          {:error, key_id_or_device_id, error}

        {:ok, _updated_device} ->
          :ok
      end
    end)
    |> Enum.reduce(_failures = %{}, fn
      :ok, failures ->
        failures

      {:error, key_id_or_device_id, error}, failures ->
        RadioBeam.AccessExtras.put_nested(failures, [signer_user_id, key_id_or_device_id], error)
    end)
  end

  defp try_update_device_with_signatures(user_id, maybe_device_id, key_params) do
    Database.update_user_device_with(user_id, maybe_device_id, fn %Device{} = device ->
      case Database.fetch_keys(user_id) do
        {:ok, %__MODULE__{cross_signing_key_ring: %{self: %CrossSigningKey{id: ssk_id} = self_signing_key}}} ->
          with :ok <- assert_signature_present(key_params, user_id, "ed25519:#{ssk_id}") do
            Device.put_identity_keys_signature(device, user_id, key_params, self_signing_key)
          end

        {:error, :not_found} ->
          {:error, :signer_has_no_self_csk}
      end
    end)
  end

  defp try_update_csk_with_signatures(signer_user_id, signer_device_id, maybe_key_id, key_params) do
    Database.update_keys(signer_user_id, fn %__MODULE__{} = keys ->
      case keys.cross_signing_key_ring do
        # MSK must be signed by a device...
        %{master: %CrossSigningKey{id: ^maybe_key_id} = msk} ->
          # ...or more specifically, the signer_device_id that is POSTing this request
          algo_and_device_id = "ed25519:#{signer_device_id}"

          with :ok <- assert_signature_present(key_params, signer_user_id, algo_and_device_id),
               {:ok, verify_key} <-
                 make_verify_key_from_device_id_key(signer_user_id, signer_device_id, algo_and_device_id),
               {:ok, new_msk} <-
                 CrossSigningKey.put_signature(msk, signer_user_id, key_params, signer_user_id, verify_key) do
            {:ok, put_in(keys.cross_signing_key_ring.master, new_msk)}
          end

        # the SSK and USK must be signed by the MSK
        %{self: %CrossSigningKey{id: ^maybe_key_id} = ssk} ->
          try_put_user_or_self_signature(signer_user_id, keys, ssk, key_params)

        %{user: %CrossSigningKey{id: ^maybe_key_id} = usk} ->
          try_put_user_or_self_signature(signer_user_id, keys, usk, key_params)

        _else ->
          {:error, :signature_key_not_known}
      end
    end)
  end

  defp assert_signature_present(key_params, signer_user_id, signing_key_id_with_algo) do
    if is_binary(key_params["signatures"][signer_user_id][signing_key_id_with_algo]),
      do: :ok,
      else: {:error, :missing_signature}
  end

  defp try_put_others_msk_signatures(others_msk_signatures, signer_user_id) do
    case Database.fetch_keys(signer_user_id) do
      {:ok, %__MODULE__{cross_signing_key_ring: %{user: %CrossSigningKey{} = signer_usk}}} ->
        others_msk_signatures
        |> Stream.flat_map(fn {user_id, key_map} ->
          Stream.map(key_map, fn {keyb64, key_params} ->
            {user_id, keyb64, key_params}
          end)
        end)
        |> Enum.reduce(_failures = %{}, fn {user_id, keyb64, key_params}, failures ->
          result =
            Database.update_keys(user_id, fn
              %__MODULE__{cross_signing_key_ring: %{master: %CrossSigningKey{id: ^keyb64} = user_msk}} = user_keys ->
                case CrossSigningKey.put_signature(user_msk, user_id, key_params, signer_user_id, signer_usk) do
                  {:ok, new_user_msk} -> {:ok, put_in(user_keys.cross_signing_key_ring.master, new_user_msk)}
                  {:error, error} -> RadioBeam.AccessExtras.put_nested(failures, [user_id, keyb64], error)
                end

              _else ->
                RadioBeam.AccessExtras.put_nested(failures, [user_id, keyb64], :signature_key_not_known)
            end)

          case result do
            {:error, :not_found} -> RadioBeam.AccessExtras.put_nested(failures, [user_id, keyb64], :user_not_found)
            {:ok, _} -> failures
            %{} = failures -> failures
          end
        end)

      {:error, :not_found} ->
        for {user_id, key_map} <- others_msk_signatures, {keyb64, _key_params} <- key_map, into: _failures = %{} do
          {user_id, %{keyb64 => :signer_has_no_user_csk}}
        end
    end
  end

  defp make_verify_key_from_device_id_key(user_id, device_id, algo_and_device_id) do
    with {:ok, device} <- Database.fetch_user_device(user_id, device_id),
         %Device{identity_keys: %{"keys" => %{^algo_and_device_id => key}}} <- device do
      {:ok, Polyjuice.Util.make_verify_key(key, algo_and_device_id)}
    else
      _ -> {:error, :signature_key_not_known}
    end
  end

  defp try_put_user_or_self_signature(signer_user_id, keys, usk_or_ssk, key_params) do
    case keys.cross_signing_key_ring do
      %{master: %CrossSigningKey{} = msk} ->
        with {:ok, csk} <- CrossSigningKey.put_signature(usk_or_ssk, signer_user_id, key_params, signer_user_id, msk) do
          case csk do
            %CrossSigningKey{usages: ["user"]} -> {:ok, put_in(keys.cross_signing_key_ring.user, csk)}
            %CrossSigningKey{usages: ["self"]} -> {:ok, put_in(keys.cross_signing_key_ring.self, csk)}
          end
        end

      _else ->
        {:error, :signature_key_not_known}
    end
  end
end
