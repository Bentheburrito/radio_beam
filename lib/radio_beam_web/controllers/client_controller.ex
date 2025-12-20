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
    response =
      %{
        device_id: device.id,
        display_name: device.display_name,
        last_seen_ts: device.last_seen_at
      }

    if is_nil(device.last_seen_from_ip) do
      response
    else
      Map.put(response, :last_seen_ip, ip_tuple_to_string(device.last_seen_from_ip))
    end
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

    with {:ok, handle} <- Transaction.begin(txn_id, device.id, conn.request_path) do
      case Device.Message.put_many(request["messages"], user.id, type) do
        :ok ->
          Transaction.done(handle, %{})
          json(conn, %{})

        {:error, :no_message} ->
          Transaction.abort(handle)

          conn
          |> put_status(400)
          |> json(Errors.bad_json("Please provide send-to-device messages under the 'messages' key."))

        {:error, :not_found} ->
          Transaction.abort(handle)

          conn
          |> put_status(400)
          |> json(Errors.bad_json("Request includes unknown users or device IDs"))

        {:error, error} ->
          Transaction.abort(handle)
          Logger.error("Error putting batch of to-device messages for: #{inspect(error)}")

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
    end
  end
end
