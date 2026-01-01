defmodule RadioBeamWeb.RoomKeysController do
  @moduledoc """
  Endpoints for retrieving and uploading media and files
  """
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 3, json_error: 4]

  alias RadioBeam.Errors
  alias RadioBeam.User.Keys
  alias RadioBeamWeb.Schemas.RoomKeys, as: RoomKeysSchema

  require Logger

  @no_schemas ~w|get_backup_info delete_backup get_keys delete_keys|a

  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: RoomKeysSchema] when action not in @no_schemas

  @unknown_backup "Unknown backup version"
  @no_key_msg "Key not found"

  def get_keys(conn, %{"version" => version} = params) when is_binary(version) do
    case Integer.parse(version) do
      {version, ""} -> get_keys(conn, Map.put(params, "version", version))
      :error -> json_error(conn, 400, :not_found, @unknown_backup)
    end
  end

  def get_keys(conn, %{"version" => version} = params) do
    user_id = conn.assigns.user_id
    room_id = Map.get(params, "room_id", :all)
    session_id = Map.get(params, "session_id", :all)

    case Keys.fetch_room_keys_backup(user_id, version, room_id, session_id) do
      {:error, :not_found} when room_id != :all and session_id == :all -> json(conn, %{"sessions" => %{}})
      {:error, :not_found} when room_id != :all and session_id != :all -> json_error(conn, 404, :not_found, @no_key_msg)
      {:error, :not_found} -> json_error(conn, 404, :not_found, @unknown_backup)
      {:error, :bad_request} -> json_error(conn, 400, :bad_json)
      {:ok, backup_data} when room_id != :all and session_id == :all -> json(conn, %{"sessions" => backup_data})
      {:ok, backup_data} -> json(conn, backup_data)
    end
  end

  def get_keys(conn, _params), do: json_error(conn, 400, :bad_json, "'version' is required")

  def put_keys(conn, %{"version" => version} = params) when is_binary(version) do
    case Integer.parse(version) do
      {version, ""} -> put_keys(conn, Map.put(params, "version", version))
      :error -> json_error(conn, 400, :not_found, @unknown_backup)
    end
  end

  def put_keys(conn, %{"version" => version} = params) do
    user_id = conn.assigns.user_id

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

    case Keys.put_room_keys_backup(user_id, version, new_room_session_backups) do
      {:ok, backup_info} ->
        json(conn, backup_info)

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
    user_id = conn.assigns.user_id

    path_or_all =
      case params do
        %{"room_id" => room_id, "session_id" => session_id} -> [room_id, session_id]
        %{"room_id" => room_id} -> [room_id]
        _else -> :all
      end

    case Keys.delete_room_keys_backup(user_id, version, path_or_all) do
      {:ok, backup_info} -> json(conn, backup_info)
      {:error, :not_found} -> json_error(conn, 404, :not_found, @unknown_backup)
    end
  end

  def delete_keys(conn, _params), do: json_error(conn, 400, :bad_json, "'version' is required")

  def create_backup(conn, _params) do
    user_id = conn.assigns.user_id
    %{"algorithm" => algorithm, "auth_data" => auth_data} = conn.assigns.request

    case Keys.create_room_keys_backup(user_id, algorithm, auth_data) do
      {:ok, version} ->
        json(conn, %{version: version})

      {:error, :unsupported_algorithm} ->
        json_error(conn, 400, :bad_json, "Unsupported algorithm")

      {:error, error} ->
        Logger.error("#{inspect(__MODULE__)}.create_backup/2: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end

  def get_backup_info(conn, params) do
    user_id = conn.assigns.user_id

    version_result =
      case Map.fetch(params, "version") do
        {:ok, version} ->
          case Integer.parse(version) do
            {version, ""} -> {:ok, version}
            :error -> {:error, :not_found}
          end

        :error ->
          {:ok, :latest}
      end

    with {:ok, version} <- version_result,
         {:ok, backup_info} <- Keys.fetch_backup_info(user_id, version) do
      json(conn, backup_info)
    else
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
    user_id = conn.assigns.user_id
    %{"algorithm" => algorithm, "auth_data" => auth_data} = conn.assigns.request

    case Keys.update_room_keys_backup_auth_data(user_id, version, algorithm, auth_data) do
      :ok ->
        json(conn, %{})

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
    case Keys.delete_room_keys_backup(conn.assigns.user_id, version) do
      :ok ->
        json(conn, %{})

      {:error, :not_found} ->
        json_error(conn, 404, :not_found, @unknown_backup)

      {:error, error} ->
        Logger.error("#{inspect(__MODULE__)}.delete_backup/2: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end

  def delete_backup(conn, _params), do: json_error(conn, 400, :bad_json, "'version' is required")
end
