defmodule RadioBeam.User.RoomKeys.Backup do
  @moduledoc false
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
    new_room_session_backups =
      Map.new(new_room_session_backups, fn {room_id, session_map} ->
        {room_id,
         Map.new(session_map, fn {session_id, key_data_attrs} -> {session_id, KeyData.new!(key_data_attrs)} end)}
      end)

    backup.room_session_backups
    |> update_in(&merge_room_session_backups(&1, new_room_session_backups))
    |> inc_modified_count()
  end

  defp merge_room_session_backups(current_backups, new_backups) do
    Map.merge(current_backups, new_backups, fn _room_id, current_session_map, new_session_map ->
      Map.merge(current_session_map, new_session_map, &choose_backup/3)
    end)
  end

  defp choose_backup(_k, %KeyData{} = kd1, %KeyData{} = kd2) do
    if KeyData.compare(kd1, kd2) == :lt, do: kd1, else: kd2
  end

  def delete_keys_under(%__MODULE__{} = backup, :all),
    do: backup.room_session_backups |> put_in(%{}) |> inc_modified_count()

  def delete_keys_under(%__MODULE__{} = backup, ["!" <> _ = room_id]),
    do: backup.room_session_backups |> update_in(&Map.delete(&1, room_id)) |> inc_modified_count()

  def delete_keys_under(%__MODULE__{} = backup, ["!" <> _ = room_id, session_id]),
    do: backup.room_session_backups[room_id] |> update_in(&Map.delete(&1, session_id)) |> inc_modified_count()

  defp inc_modified_count(%__MODULE__{} = backup), do: update_in(backup.modified_count, &(&1 + 1))

  def info_map(%__MODULE__{} = backup) do
    %{
      algorithm: backup.algorithm,
      auth_data: backup.auth_data,
      count: count(backup),
      etag: Integer.to_string(backup.modified_count),
      version: Integer.to_string(backup.version)
    }
  end

  defimpl JSON.Encoder do
    def encode(backup, encoder) do
      rooms =
        Map.new(backup.room_session_backups, fn {room_id, session_map} -> {room_id, %{"sessions" => session_map}} end)

      JSON.Encoder.Map.encode(%{"rooms" => rooms}, encoder)
    end
  end
end
