defmodule RadioBeamWeb.DeviceKeysController do
  @moduledoc """
  Endpoints for retrieving and uploading media and files
  """
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 3]

  alias RadioBeam.Device.OneTimeKeyRing
  alias RadioBeam.Device
  alias RadioBeamWeb.Schemas.DeviceKeys, as: DeviceKeysSchema

  require Logger

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: DeviceKeysSchema

  def upload(conn, _params) do
    user_id = conn.assigns.user.id
    device_id = conn.assigns.device.id

    opts =
      Keyword.new(conn.assigns.request, fn
        {"one_time_keys", otks} -> {:one_time_keys, otks}
        {"fallback_keys", fallback_keys} -> {:fallback_keys, fallback_keys}
      end)

    case Device.put_keys(user_id, device_id, opts) do
      {:ok, %Device{one_time_key_ring: otk_ring}} ->
        json(conn, %{"one_time_key_counts" => OneTimeKeyRing.one_time_key_counts(otk_ring)})

      {:error, error} when error in ~w|not_found user_does_not_exist|a ->
        Logger.error(
          "Something has gone very wrong while #{inspect(device_id)} was uploading new keys: #{inspect(error)}"
        )

        json_error(conn, 500, :unknown)
    end
  end

  def claim(conn, _params) do
    with otks when is_map(otks) <- Device.claim_otks(conn.assigns.request["one_time_keys"]) do
      json(conn, %{"one_time_keys" => otks})
    end
  end
end
