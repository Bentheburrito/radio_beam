defmodule RadioBeamWeb.RoomKeysController do
  @moduledoc """
  Endpoints for retrieving and uploading media and files
  """
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 3, json_error: 4]

  alias RadioBeam.Errors
  alias RadioBeam.User
  alias RadioBeam.User.RoomKeys
  alias RadioBeam.User.RoomKeys.Backup
  alias RadioBeamWeb.Schemas.RoomKeys, as: RoomKeysSchema

  require Logger

  @no_schemas ~w|get_backup_info delete_backup get_keys delete_keys|a

  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: RoomKeysSchema] when action not in @no_schemas

  @unknown_backup "Unknown backup version"

  def get_keys(conn, %{"version" => version} = params) when is_binary(version) do
    case Integer.parse(version) do
      {version, ""} -> get_keys(conn, Map.put(params, "version", version))
      :error -> json_error(conn, 400, :not_found, @unknown_backup)
    end
  end

  def get_keys(conn, %{"version" => version} = params) do
    %User{} = user = conn.assigns.session.user

    case RoomKeys.fetch_backup(user.room_keys, version) do
      {:ok, %Backup{} = backup} -> get_keys_response(conn, params, backup)
      {:error, :not_found} -> json_error(conn, 404, :not_found, @unknown_backup)
    end
  end

  def get_keys(conn, _params), do: json_error(conn, 400, :bad_json, "'version' is required")

  defp get_keys_response(conn, params, %Backup{} = backup) do
    case params do
      %{"room_id" => room_id, "session_id" => session_id} ->
        case Backup.get(backup, room_id, session_id) do
          {:error, :not_found} -> json_error(conn, 404, :not_found, "Key not found")
          %Backup.KeyData{} = key_data -> json(conn, key_data)
        end

      %{"room_id" => room_id} ->
        case Backup.get(backup, room_id) do
          {:error, :not_found} -> json(conn, %{"sessions" => %{}})
          %{} = session_map -> json(conn, %{"sessions" => session_map})
        end

      _else ->
        json(conn, backup)
    end
  end

  def put_keys(conn, %{"version" => version} = params) when is_binary(version) do
    case Integer.parse(version) do
      {version, ""} -> put_keys(conn, Map.put(params, "version", version))
      :error -> json_error(conn, 400, :not_found, @unknown_backup)
    end
  end

  def put_keys(conn, %{"version" => version} = params) do
    %User{} = user = conn.assigns.session.user

    new_room_session_backups =
      case params do
        %{"room_id" => room_id, "session_id" => session_id} ->
          %{room_id => %{session_id => conn.assigns.request}}

        %{"room_id" => room_id} ->
          %{room_id => Map.fetch!(conn.assigns.request, "sessions")}

        _else ->
          conn.assigns.request
          |> Map.fetch!("rooms")
          |> Map.new(fn {room_id, %{"sessions" => session_map}} -> {room_id, session_map} end)
      end

    with %RoomKeys{} = room_keys <- RoomKeys.put_backup_keys(user.room_keys, version, new_room_session_backups),
         {:ok, %User{}} <- RoomKeys.insert_user_room_keys(user, room_keys),
         {:ok, %Backup{} = backup} <- RoomKeys.fetch_backup(room_keys, version) do
      json(conn, backup |> Backup.info_map() |> Map.take(~w|count etag|a))
    else
      {:error, :not_found} ->
        json_error(conn, 404, :not_found, @unknown_backup)

      {:error, :wrong_room_keys_version, current_version} ->
        error =
          :wrong_room_keys_version
          |> Errors.endpoint_error("Cannot add keys to an old backup")
          |> Map.put(:current_version, current_version)

        conn |> put_status(403) |> json(error)

      {:error, error} ->
        Logger.error("#{inspect(__MODULE__)}.put_keys/2: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end

  def put_keys(conn, _params), do: json_error(conn, 400, :bad_json, "'version' is required")

  def delete_keys(conn, %{"version" => version} = params) when is_binary(version) do
    case Integer.parse(version) do
      {version, ""} -> delete_keys(conn, Map.put(params, "version", version))
      :error -> json_error(conn, 400, :not_found, @unknown_backup)
    end
  end

  def delete_keys(conn, %{"version" => version} = params) do
    %User{} = user = conn.assigns.session.user

    path_or_all =
      case params do
        %{"room_id" => room_id, "session_id" => session_id} -> [room_id, session_id]
        %{"room_id" => room_id} -> [room_id]
        _else -> :all
      end

    with %RoomKeys{} = room_keys <- RoomKeys.delete_backup_keys(user.room_keys, version, path_or_all),
         {:ok, %Backup{} = backup} <- RoomKeys.fetch_backup(room_keys, version) do
      json(conn, backup |> Backup.info_map() |> Map.take(~w|count etag|a))
    else
      {:error, :not_found} -> json_error(conn, 404, :not_found, @unknown_backup)
    end
  end

  def delete_keys(conn, _params), do: json_error(conn, 400, :bad_json, "'version' is required")

  def create_backup(conn, _params) do
    %User{} = user = conn.assigns.session.user
    %{"algorithm" => algorithm, "auth_data" => auth_data} = conn.assigns.request

    with %RoomKeys{} = room_keys <- RoomKeys.new_backup(user.room_keys, algorithm, auth_data),
         {:ok, %User{}} <- RoomKeys.insert_user_room_keys(user, room_keys),
         {:ok, %Backup{} = backup} <- RoomKeys.fetch_latest_backup(room_keys) do
      json(conn, %{version: backup |> Backup.version() |> Integer.to_string()})
    else
      {:error, :unsupported_algorithm} ->
        json_error(conn, 400, :bad_json, "Unsupported algorithm")

      {:error, error} ->
        Logger.error("#{inspect(__MODULE__)}.create_backup/2: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end

  def get_backup_info(conn, params) do
    %User{} = user = conn.assigns.session.user

    backup_result =
      case Map.fetch(params, "version") do
        {:ok, version} ->
          case Integer.parse(version) do
            {version, ""} -> RoomKeys.fetch_backup(user.room_keys, version)
            :error -> {:error, :not_found}
          end

        :error ->
          RoomKeys.fetch_latest_backup(user.room_keys)
      end

    case backup_result do
      {:ok, %Backup{} = backup} -> json(conn, Backup.info_map(backup))
      {:error, :not_found} -> json_error(conn, 404, :not_found, "Backup not found")
    end
  end

  def put_backup_auth_data(%{body_params: %{"version" => v1}} = conn, %{"version" => v2}) when v1 != v2 do
    json_error(conn, 400, :endpoint_error, [:invalid_param, "version does not match"])
  end

  def put_backup_auth_data(conn, %{"version" => version}) do
    case Integer.parse(version) do
      {version, ""} -> put_backup_auth_data(conn, version)
      :error -> json_error(conn, 400, :not_found, @unknown_backup)
    end
  end

  def put_backup_auth_data(conn, version) when is_integer(version) do
    %User{} = user = conn.assigns.session.user
    %{"algorithm" => algorithm, "auth_data" => auth_data} = conn.assigns.request

    with {:ok, %RoomKeys{} = room_keys} <- RoomKeys.update_backup(user.room_keys, version, algorithm, auth_data),
         {:ok, %User{}} <- RoomKeys.insert_user_room_keys(user, room_keys) do
      json(conn, %{})
    else
      {:error, :algorithm_mismatch} ->
        json_error(conn, 400, :endpoint_error, [:invalid_param, "algorithm does not match"])

      {:error, :not_found} ->
        json_error(conn, 404, :not_found, @unknown_backup)

      {:error, error} ->
        Logger.error("#{inspect(__MODULE__)}.put_backup_auth_data/2: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end

  def put_backup_auth_data(conn, _params), do: json_error(conn, 400, :bad_json, "'version' is required")

  def delete_backup(conn, %{"version" => version} = params) when is_binary(version) do
    case Integer.parse(version) do
      {version, ""} -> delete_backup(conn, Map.put(params, "version", version))
      :error -> json_error(conn, 400, :not_found, @unknown_backup)
    end
  end

  def delete_backup(conn, %{"version" => version}) do
    %User{} = user = conn.assigns.session.user

    with %RoomKeys{} = room_keys <- RoomKeys.delete_backup(user.room_keys, version),
         {:ok, %User{}} <- RoomKeys.insert_user_room_keys(user, room_keys) do
      json(conn, %{})
    else
      {:error, :not_found} ->
        json_error(conn, 404, :not_found, @unknown_backup)

      {:error, error} ->
        Logger.error("#{inspect(__MODULE__)}.delete_backup/2: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end

  def delete_backup(conn, _params), do: json_error(conn, 400, :bad_json, "'version' is required")
end
