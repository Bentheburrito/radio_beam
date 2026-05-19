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
    case Authentication.authn_and_authz_user_by_access_token(access_token, conn.remote_ip, conn.path_info) do
      {:ok, user_id, device_id} ->
        conn
        |> assign(:user_id, user_id)
        |> assign(:device_id, device_id)

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
