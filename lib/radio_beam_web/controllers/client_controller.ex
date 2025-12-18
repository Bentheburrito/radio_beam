defmodule RadioBeamWeb.ClientController do
  @moduledoc """
  Top-level endpoints for the Client-Server API.
  """
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 3, json_error: 4]

  alias RadioBeam.Transaction
  alias RadioBeam.Errors
  alias RadioBeam.User
  alias RadioBeam.User.Device

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: RadioBeamWeb.Schemas.Client] when action in ~w|send_to_device|a

  def get_device(%{assigns: %{session: %{user: user}}} = conn, params) do
    case Map.fetch(params, "device_id") do
      {:ok, device_id} ->
        case User.get_device(user, device_id) do
          {:ok, %Device{} = device} -> json(conn, get_device_response(device))
          {:error, :not_found} -> json_error(conn, 404, :not_found, "no device by that ID")
        end

      :error ->
        devices = User.get_all_devices(user)
        json(conn, %{devices: Enum.map(devices, &get_device_response/1)})
    end
  end

  defp get_device_response(%Device{} = device) do
    %{
      device_id: device.id,
      display_name: device.display_name,
      last_seen_ip: ip_tuple_to_string(device.last_seen_from_ip),
      last_seen_ts: device.last_seen_at
    }
  end

  def put_device_display_name(conn, %{"device_id" => device_id, "display_name" => display_name}) do
    case User.Account.put_device_display_name(conn.assigns.session.user.id, device_id, display_name) do
      {:ok, %User{}} -> json(conn, %{})
      {:error, :not_found} -> json_error(conn, 404, :not_found, "device not found")
      {:error, error} -> log_error(conn, error)
    end
  end

  def put_device_display_name(conn, _params), do: json(conn, %{})

  defp log_error(conn, error) do
    Logger.error("#{__MODULE__}: #{inspect(error)}")
    json_error(conn, 500, :unknown)
  end

  defp ip_tuple_to_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  def send_to_device(conn, %{"type" => type, "transaction_id" => txn_id}) do
    %User{} = user = conn.assigns.session.user
    %Device{} = device = conn.assigns.session.device
    request = conn.assigns.request

    with parsed_args when is_list(parsed_args) <- parse_args(request["messages"], user.id, type),
         {:ok, handle} <- Transaction.begin(txn_id, device.id, conn.request_path) do
      case Device.Message.put_many(parsed_args) do
        {:ok, _count} ->
          Transaction.done(handle, %{})
          json(conn, %{})

        {:error, fxn_name, error} ->
          Transaction.abort(handle)
          Logger.error("Error putting batch of to-device messages for #{inspect(fxn_name)}: #{inspect(error)}")

          conn
          |> put_status(500)
          |> json(Errors.unknown())
      end
    else
      {:already_done, response} ->
        json(conn, response)

      :federation_unimplemented ->
        conn
        |> put_status(404)
        |> json(Errors.unrecognized("Device messages over federation are currently unimplemented"))

      :error ->
        conn
        |> put_status(500)
        |> json(Errors.unknown())

      :no_messages ->
        conn
        |> put_status(400)
        |> json(Errors.bad_json("Please provide send-to-device messages under the 'messages' key."))
    end
  end

  defp parse_args(nil, _sender_id, _type), do: :no_messages
  defp parse_args(empty, _sender_id, _type) when map_size(empty) == 0, do: :no_messages

  defp parse_args(messages, sender_id, type) do
    servername = RadioBeam.server_name()

    for {"@" <> _rest = user_id, %{} = device_map} <- messages,
        {device_id_or_glob, msg_content} <- device_map,
        device_id <- Device.Message.expand_device_id(user_id, device_id_or_glob) do
      case String.split(user_id, ":") do
        ["@" <> _localpart, ^servername] ->
          {user_id, device_id, Device.Message.new(msg_content, sender_id, type)}

        # TOIMPL: put device over federation
        ["@" <> _localpart, _domain] ->
          throw(:federation_unimplemented)
      end
    end
  catch
    error -> error
  end
end
