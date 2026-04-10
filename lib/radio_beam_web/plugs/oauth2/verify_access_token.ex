defmodule RadioBeamWeb.Plugs.OAuth2.VerifyAccessToken do
  @moduledoc """
  Requires the `access_token` included in the request, authenticating and
  authorizing the user it belongs to via `RadioBeam.User.Authentication`.
  """
  import Plug.Conn
  import RadioBeamWeb.Utils, only: [json_error: 3, json_error: 4]

  alias RadioBeam.User.Authentication

  require Logger

  def init(default), do: default

  def call(%{assigns: %{access_token: access_token}} = conn, _opts) do
    case Authentication.authn_and_authz_user_by_access_token(access_token, conn.remote_ip, conn.path_info) do
      {:ok, user_id, device_id} ->
        conn
        |> assign(:user_id, user_id)
        |> assign(:device_id, device_id)

      {:error, :account_locked} ->
        conn |> json_error(401, :user_locked, ["Your account has been locked by an administrator"]) |> halt()

      {:error, :account_suspended} ->
        conn |> json_error(403, :user_suspended, ["Your account has been suspended by an administrator"]) |> halt()

      {:error, :token_expired} ->
        conn |> json_error(401, :unknown_token, ["Unknown token", true]) |> halt()

      {:error, :invalid_token} ->
        conn |> json_error(401, :unknown_token, ["Unknown token", false]) |> halt()

      {:error, error} ->
        Logger.error("A fatal error occurred trying to authenticate a device's session: #{inspect(error)}")
        conn |> json_error(500, :unknown) |> halt()
    end
  end

  def call(conn, opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        conn |> assign(:access_token, token) |> call(opts)

      _else ->
        # since supplying the access token in the query params has been
        # deprecated since v1.11, I think we should expect clients impling
        # the OAuth2 API will have switched to supplying exclusively via
        # the header now
        conn |> json_error(401, :missing_token) |> halt()
    end
  end
end
