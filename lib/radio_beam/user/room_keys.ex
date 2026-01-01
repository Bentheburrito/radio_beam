defmodule RadioBeam.User.RoomKeys do
  @moduledoc """
  Functionality to allow users to upload E2EE keys that can be shared between
  their devices, as described in [the
  spec](https://spec.matrix.org/latest/client-server-api/#server-side-key-backups).
  """
  alias RadioBeam.User.RoomKeys.Backup

  @allowed_algos ["m.megolm_backup.v1.curve25519-aes-sha2"]
  def allowed_algorithms, do: @allowed_algos

  # backups: %{version => %Backup{}}
  defstruct backups: %{}, latest_version: 0

  def new!, do: %__MODULE__{}

  def new_backup(%__MODULE__{} = room_keys, algorithm, auth_data) when algorithm in @allowed_algos do
    room_keys = put_in(room_keys.latest_version, room_keys.latest_version + 1)

    put_in(room_keys.backups[room_keys.latest_version], Backup.new!(algorithm, auth_data, room_keys.latest_version))
  end

  def new_backup(%__MODULE__{}, _algo, _auth_data), do: {:error, :unsupported_algorithm}

  def fetch_latest_backup(%__MODULE__{backups: backups}) when map_size(backups) == 0, do: {:error, :not_found}
  def fetch_latest_backup(%__MODULE__{} = room_keys), do: {:ok, Map.fetch!(room_keys.backups, room_keys.latest_version)}

  def fetch_backup(%__MODULE__{} = room_keys, version) do
    with :error <- Map.fetch(room_keys.backups, version), do: {:error, :not_found}
  end

  def update_backup(%__MODULE__{} = room_keys, version, algorithm, auth_data) do
    case Map.fetch(room_keys.backups, version) do
      {:ok, %Backup{algorithm: ^algorithm} = backup} ->
        {:ok, put_in(room_keys.backups[version], Backup.put_auth_data!(backup, auth_data))}

      {:ok, %Backup{}} ->
        {:error, :algorithm_mismatch}

      :error ->
        {:error, :not_found}
    end
  end

  def delete_backup(%__MODULE__{} = room_keys, version) when version in 1..room_keys.latest_version//1 do
    update_in(room_keys.backups, &Map.delete(&1, version))
  end

  def delete_backup(%__MODULE__{}, _version), do: {:error, :not_found}

  def put_backup_keys(%__MODULE__{}, 0, _new_room_session_backups), do: {:error, :not_found}

  def put_backup_keys(%__MODULE__{latest_version: version} = room_keys, version, new_room_session_backups) do
    %Backup{} = backup = Map.fetch!(room_keys.backups, version)
    put_in(room_keys.backups[version], Backup.put_keys(backup, new_room_session_backups))
  end

  def put_backup_keys(%__MODULE__{latest_version: current_version}, _version, _new_room_session_backups),
    do: {:error, :wrong_room_keys_version, current_version}

  def delete_backup_keys(%__MODULE__{} = room_keys, version, path_or_all \\ :all) do
    case Map.fetch(room_keys.backups, version) do
      {:ok, %Backup{} = backup} ->
        put_in(room_keys.backups[version], Backup.delete_keys_under(backup, path_or_all))

      :error ->
        {:error, :not_found}
    end
  end
end
