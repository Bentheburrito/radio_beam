defmodule RadioBeam.User.RoomKeys.Backup do
  alias RadioBeam.User.RoomKeys.Backup.KeyData

  # room_session_backups: %{room_id => %{session_id => %KeyData{}}}
  @attrs ~w|algorithm auth_data modified_count room_session_backups version|a
  @enforce_keys @attrs
  defstruct @attrs

  def new!(algorithm, auth_data, version) do
    %__MODULE__{
      algorithm: algorithm,
      auth_data: auth_data,
      modified_count: 0,
      room_session_backups: %{},
      version: version
    }
  end

  def count(%__MODULE__{room_session_backups: backups}),
    do: backups |> Stream.map(fn {_room_id, session_map} -> map_size(session_map) end) |> Enum.sum()

  def version(%__MODULE__{version: version}), do: version

  def put_auth_data!(%__MODULE__{} = backup, auth_data), do: put_in(backup.auth_data, auth_data)

  def get(%__MODULE__{} = backup), do: backup.room_session_backups
  def get(%__MODULE__{} = backup, room_id), do: backup.room_session_backups[room_id] || {:error, :not_found}

  def get(%__MODULE__{} = backup, room_id, session_id),
    do: backup.room_session_backups[room_id][session_id] || {:error, :not_found}

  def put_keys(%__MODULE__{} = backup, new_room_session_backups) do
    update_in(backup.room_session_backups, &merge_room_session_backups(&1, new_room_session_backups))
  end

  defp merge_room_session_backups(current_backups, new_backups) do
    Map.merge(current_backups, new_backups, fn _room_id, current_session_map, new_session_map ->
      Map.merge(current_session_map, new_session_map, &choose_backup/2)
    end)
  end

  defp choose_backup(%KeyData{} = kd1, %KeyData{} = kd2), do: if(KeyData.compare(kd1, kd2) == :lt, do: kd1, else: kd2)
  defp choose_backup(%KeyData{} = kd1, %{} = kd2_attrs), do: choose_backup(kd1, KeyData.new!(kd2_attrs))
  defp choose_backup(%{} = kd1_attrs, %KeyData{} = kd2), do: choose_backup(KeyData.new!(kd1_attrs), kd2)

  def delete_keys_under(%__MODULE__{} = backup, :all), do: put_in(backup.room_session_backups, %{})

  def delete_keys_under(%__MODULE__{} = backup, ["!" <> _ = room_id]),
    do: update_in(backup.room_session_backups, &Map.delete(&1, room_id))

  def delete_keys_under(%__MODULE__{} = backup, ["!" <> _ = room_id, session_id]),
    do: update_in(backup.room_session_backups[room_id], &Map.delete(&1, session_id))
end
