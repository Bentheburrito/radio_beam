defmodule RadioBeamWeb.ClientController do
  @moduledoc """
  Top-level endpoints for the Client-Server API.
  """
  use RadioBeamWeb, :controller

  require Logger
  alias RadioBeam.Transaction
  alias RadioBeam.Errors
  alias RadioBeam.Device
  alias RadioBeam.User

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RadioBeamWeb.Schemas.Client

  def send_to_device(conn, %{"type" => type, "transaction_id" => txn_id}) do
    %User{} = user = conn.assigns.user
    %Device{} = device = conn.assigns.device
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
