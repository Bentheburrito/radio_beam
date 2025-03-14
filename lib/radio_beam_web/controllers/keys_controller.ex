defmodule RadioBeamWeb.KeysController do
  @moduledoc """
  Endpoints for retrieving and uploading media and files
  """
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 3, json_error: 4]

  alias RadioBeam.Errors
  alias RadioBeam.User.Keys
  alias RadioBeam.User
  alias RadioBeam.User.CrossSigningKeyRing
  alias RadioBeam.User.Device.OneTimeKeyRing
  alias RadioBeam.User.Device
  alias RadioBeamWeb.Schemas.Keys, as: KeysSchema

  require Logger

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: KeysSchema

  @creds_dont_match_msg "The user/device ID specified in 'device_keys' do not match your session."

  def upload(conn, _params) do
    user = conn.assigns.user
    device_id = conn.assigns.device.id

    opts =
      Keyword.new(conn.assigns.request, fn
        {"device_keys", identity_keys} -> {:identity_keys, identity_keys}
        {"one_time_keys", otks} -> {:one_time_keys, otks}
        {"fallback_keys", fallback_keys} -> {:fallback_keys, fallback_keys}
      end)

    case Device.Keys.put(user, device_id, opts) do
      {:ok, %User{device_map: %{^device_id => %{one_time_key_ring: otk_ring}}}} ->
        json(conn, %{"one_time_key_counts" => OneTimeKeyRing.one_time_key_counts(otk_ring)})

      {:error, :invalid_user_or_device_id} ->
        json_error(conn, 400, :bad_json, @creds_dont_match_msg)

      {:error, error} when error in ~w|not_found user_does_not_exist|a ->
        Logger.error(
          "Something has gone very wrong while #{inspect(device_id)} was uploading new keys: #{inspect(error)}"
        )

        json_error(conn, 500, :unknown)
    end
  end

  @user_id_mismatch_msg "The user_id specified on one or more of the supplied keys do not match the owner of the device."
  @bad_signature_msg "When uploading self-/user-cross-signing keys, they must be signed by an accompanying (or previously uploaded) master key."
  def upload_cross_signing(conn, _params) do
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
        json_error(conn, 400, :endpoint_error, [:invalid_param, "Invalid/missing `keys` param"])

      {:error, :user_ids_do_not_match} ->
        json_error(conn, 400, :endpoint_error, [:invalid_param, @user_id_mismatch_msg])

      {:error, error} when error in ~w|missing_master_key missing_or_invalid_master_key_signatures|a ->
        json_error(conn, 400, :endpoint_error, [:invalid_signature, @bad_signature_msg])

      {:error, error} when error in ~w|not_found user_does_not_exist|a ->
        Logger.error(
          "Something has gone very wrong while #{inspect(device_id)} was uploading new keys: #{inspect(error)}"
        )

        json_error(conn, 500, :unknown)
    end
  end

  @set_up_csk_msg "You must upload Cross-Signing Keys before you can upload signatures of other user's keys"
  def upload_signatures(conn, _params) do
    case Keys.put_signatures(conn.assigns.user.id, conn.assigns.request) do
      :ok -> json(conn, %{})
      {:error, :signer_has_no_user_csk} -> json_error(conn, 400, :bad_json, [@set_up_csk_msg])
      {:error, %{} = failures} -> json(conn, %{"failures" => map_nested_errors(failures)})
    end
  end

  @spec map_nested_errors(%{String.t() => %{String.t() => Keys.put_signatures_error()}}) :: map()
  defp map_nested_errors(nested_map_of_errors) do
    nested_map_of_errors
    |> Stream.flat_map(fn {user_id, error_map} ->
      Stream.map(error_map, fn {id, error} -> {user_id, id, error} end)
    end)
    |> Enum.reduce(%{}, fn
      {user_id, id, :unknown_key}, acc ->
        error = Errors.not_found("The key used to make the signature is not known to the server.")
        RadioBeam.put_nested(acc, [user_id, id], error)

      {user_id, id, :disallowed_key_type}, acc ->
        error =
          Errors.bad_json("You can only upload signatures for your own keys, or others' master cross-signing keys.")

        RadioBeam.put_nested(acc, [user_id, id], error)

      {user_id, id, :no_master_csk}, acc ->
        error = Errors.not_found("The key this signature is for is not known to the server.")
        RadioBeam.put_nested(acc, [user_id, id], error)

      {user_id, id, :user_not_found}, acc ->
        RadioBeam.put_nested(acc, [user_id, id], Errors.not_found("User not found"))

      {user_id, id, :different_keys}, acc ->
        error = Errors.bad_json("The key in the request does not match the key on the server.")
        RadioBeam.put_nested(acc, [user_id, id], error)

      {user_id, id, :invalid_signature}, acc ->
        error = Errors.endpoint_error(:invalid_signature, "The uploaded signature failed verification.")
        RadioBeam.put_nested(acc, [user_id, id], error)
    end)
  end

  def claim(conn, _params) do
    with %{} = otks <- Device.Keys.claim_otks(conn.assigns.request["one_time_keys"]) do
      json(conn, %{"one_time_keys" => otks})
    else
      error ->
        Logger.error("Expected a map as the result of Device.Keys.claim_otks, got: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end

  def query(conn, _params) do
    with %{} = user_key_map <- Keys.query_all(conn.assigns.request["device_keys"], conn.assigns.user.id) do
      json(conn, user_key_map)
    else
      error ->
        Logger.error("Expected a map as the result of Keys.query_all, got: #{inspect(error)}")
        json_error(conn, 500, :unknown)
    end
  end
end
