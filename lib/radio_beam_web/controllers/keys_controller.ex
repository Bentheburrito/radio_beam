defmodule RadioBeamWeb.KeysController do
  @moduledoc """
  Endpoints for retrieving and uploading media and files
  """
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 3, halting_json_error: 4]

  alias RadioBeam.User
  alias RadioBeam.User.CrossSigningKeyRing
  alias RadioBeam.Device.OneTimeKeyRing
  alias RadioBeam.Device
  alias RadioBeamWeb.Schemas.DeviceKeys, as: DeviceKeysSchema

  require Logger

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: DeviceKeysSchema

  @creds_dont_match_msg "The user/device ID specified in 'device_keys' do not match your session."

  def upload(conn, _params) do
    user_id = conn.assigns.user.id
    device_id = conn.assigns.device.id

    opts =
      Keyword.new(conn.assigns.request, fn
        {"device_keys", identity_keys} -> {:identity_keys, identity_keys}
        {"one_time_keys", otks} -> {:one_time_keys, otks}
        {"fallback_keys", fallback_keys} -> {:fallback_keys, fallback_keys}
      end)

    case Device.put_keys(user_id, device_id, opts) do
      {:ok, %Device{one_time_key_ring: otk_ring}} ->
        json(conn, %{"one_time_key_counts" => OneTimeKeyRing.one_time_key_counts(otk_ring)})

      {:error, :invalid_user_or_device_id} ->
        halting_json_error(conn, 400, :bad_json, @creds_dont_match_msg)

      {:error, error} when error in ~w|not_found user_does_not_exist|a ->
        Logger.error(
          "Something has gone very wrong while #{inspect(device_id)} was uploading new keys: #{inspect(error)}"
        )

        json_error(conn, 500, :unknown)
    end
  end

  @user_id_mismatch_msg "The user_id specified on one or more of the supplied keys do not match the owner of the device."
  @bad_signature_msg "When uploading self-/user-cross-signing keys, they must be signed by an accompanying (or previously uploaded) master key."
  @bad_identity_key_creds_msg "The user or device ID on the supplied identity keys do not match those associated with your access token"
  def upload_signing(conn, _params) do
    user_id = conn.assigns.user.id
    device_id = conn.assigns.device.id

    opts =
      Keyword.new(conn.assigns.request, fn
        {"master_key", master_key} -> {:master_key, master_key}
        {"self_signing_key", self_signing_key} -> {:self_signing_key, self_signing_key}
        {"user_signing_key", user_signing_key} -> {:user_signing_key, user_signing_key}
      end)

    case CrossSigningKeyRing.put(user_id, opts) do
      {:ok, %User{}} ->
        json(conn, %{})

      {:error, error} when error in ~w|too_many_keys no_key_provided malformed_key|a ->
        halting_json_error(conn, 400, :endpoint_error, [:invalid_param, "Invalid/missing `keys` param"])

      {:error, :user_ids_do_not_match} ->
        halting_json_error(conn, 400, :endpoint_error, [:invalid_param, @user_id_mismatch_msg])

      {:error, error} when error in ~w|missing_master_key missing_or_invalid_master_key_signatures|a ->
        halting_json_error(conn, 400, :endpoint_error, [:invalid_signature, @bad_signature_msg])

      {:error, :invalid_user_or_device_id} ->
        halting_json_error(conn, 400, :endpoint_error, [:invalid_param, @bad_identity_key_creds_msg])

      {:error, error} when error in ~w|not_found user_does_not_exist|a ->
        Logger.error(
          "Something has gone very wrong while #{inspect(device_id)} was uploading new keys: #{inspect(error)}"
        )

        json_error(conn, 500, :unknown)
    end
  end

  def claim(conn, _params) do
    with %{} = otks <- Device.claim_otks(conn.assigns.request["one_time_keys"]) do
      json(conn, %{"one_time_keys" => otks})
    else
      error ->
        Logger.error("Expected a map as the result of Device.claim_otks, got: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end

  def query(conn, _params) do
    with %{} = user_key_map <- User.query_all_keys(conn.assigns.request["device_keys"], conn.assigns.user.id) do
      json(conn, user_key_map)
    else
      error ->
        Logger.error("Expected a map as the result of User.query_all_keys, got: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end
end
