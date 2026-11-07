defmodule RadioBeamWeb.Plugs.OAuth2.VerifyAccessTokenCookie do
  @moduledoc """
  Requires a user to have logged in previously, else they are redirected to the
  account management home page to authenticate.
  """

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias RadioBeam.User.Authentication

  require Logger

  def init(default), do: default

  def call(%{path_info: ["account", action]} = conn, _opts) when action in ~w|login callback| do
    conn
  end

  def call(%{assigns: %{access_token: access_token}} = conn, _opts) do
    case Authentication.authn_and_authz_user_by_access_token(access_token, conn.remote_ip, conn.path_info, conn.host) do
      {:ok, request} ->
        conn
        |> assign(:user_id, request.user_id)
        |> assign(:device_id, request.device_id)
        |> assign(:cs_request, request)

      {:error, :account_locked} ->
        conn
        |> put_flash(:error, "Your account has been locked by an administrator")
        |> redirect(to: "/account/login")
        |> halt()

      {:error, :account_suspended} ->
        conn
        |> put_flash(:error, "Your account has been suspended by an administrator")
        |> redirect(to: "/account/login")
        |> halt()

      {:error, :token_expired} ->
        redirect(conn, to: "/account/login") |> halt()

      {:error, :invalid_token} ->
        redirect(conn, to: "/account/login") |> halt()

      {:error, :not_found} ->
        redirect(conn, to: "/account/login") |> halt()

      {:error, {:host, expected_host}} ->
        Logger.warning(
          "user client request used wrong host: #{inspect(conn.host)}, expected #{inspect(expected_host)}. (Did you get your wires crossed?)"
        )

        conn
        |> redirect(to: "/account/login")
        |> halt()

      {:error, :orphaned_user} ->
        Logger.error(
          "A valid user session was identified as a part of a browser session, but the corresponding homeserver on host #{conn.host} is (no longer) configured in RadioBeam"
        )

        conn
        |> put_flash(:error, "Homeserver has moved. Contact your server administrator to remedy this error")
        |> redirect(to: "/account/login")
        |> halt()

      {:error, error} ->
        Logger.error(
          "A fatal error occurred trying to authenticate a user's account management session: #{inspect(error)}"
        )

        redirect(conn, to: "/account/login") |> halt()
    end
  end

  def call(conn, opts) do
    case get_session(conn) do
      %{"access_token" => token} -> conn |> assign(:access_token, token) |> call(opts)
      _else -> redirect(conn, to: "/account/login") |> halt()
    end
  end
end
