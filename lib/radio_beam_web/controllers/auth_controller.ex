defmodule RadioBeamWeb.AuthController do
  use RadioBeamWeb, :controller

  alias RadioBeam.User.Auth
  alias RadioBeam.{Credentials, Device, Errors, Repo, User}
  alias RadioBeamWeb.Schemas.Auth, as: AuthSchema

  require Logger

  plug :ensure_registration_enabled when action == :register
  plug RadioBeamWeb.Plugs.EnforceSchema, [get_schema: {AuthSchema, :register, []}] when action == :register
  plug :ensure_user_no_exists when action == :register

  plug RadioBeamWeb.Plugs.EnforceSchema, [get_schema: {AuthSchema, :refresh, []}] when action == :refresh
  plug :authenticate_by_refresh_token when action == :refresh

  def register(conn, params) do
    with {:ok, %User{} = user} <- new_user(conn, conn.assigns.user_id, Map.fetch!(params, "password")) do
      Repo.insert!(user)

      if Map.get(params, "inhibit_login", false) do
        json(conn, %{user_id: user.id})
      else
        params = Map.put_new_lazy(params, "device_id", &Device.generate_token/0)

        conn
        |> assign(:user, user)
        |> RadioBeamWeb.LoginController.login(Map.take(params, ["device_id", "initial_device_display_name"]))
      end
    end
  end

  def refresh(conn, _params) do
    user = conn.assigns.user
    refresh_token = conn.assigns.device.refresh_token

    case Auth.refresh(user.id, refresh_token) do
      {:ok, auth_info} ->
        json(conn, auth_info)

      {:error, :not_found} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", false))

      # TODO: should add config to expire refresh tokens after X time. 
      # Currently, refresh tokens never expire, so it just lives forever unless
      # the device is destroyed from another session. Would also allow us to 
      # support soft-logout here

      {:error, error} ->
        Logger.error("Got error trying to use a refresh token: #{inspect(error)}")
        conn |> put_status(401) |> json(Errors.unknown())
    end
  end

  defp ensure_registration_enabled(conn, _) do
    if Application.get_env(:radio_beam, :registration_enabled, false) do
      case Map.get(conn.params, "kind", "user") do
        "user" ->
          conn

        "guest" ->
          conn
          |> put_status(403)
          |> json(Errors.unrecognized("This homeserver does not support guest registration at this time."))
          |> halt()

        other ->
          Logger.info("unknown `kind` provided by client during registration: #{inspect(other)}")

          conn
          |> put_status(403)
          |> json(Errors.bad_json("Expected 'user' or 'guest' as the kind, got '#{other}'"))
          |> halt()
      end
    else
      conn
      |> put_status(403)
      |> json(Errors.forbidden("Registration is not enabled on this homeserver"))
      |> halt()
    end
  end

  defp ensure_user_no_exists(conn, _) do
    server_name = Application.fetch_env!(:radio_beam, :server_name)
    user_id = "@#{Map.fetch!(conn.params, "username")}:#{server_name}"

    case Repo.get(User, user_id) do
      {:ok, %User{}} ->
        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:user_in_use, "That username is already taken."))
        |> halt()

      {:ok, nil} ->
        assign(conn, :user_id, user_id)
    end
  end

  defp new_user(conn, user_id, password) do
    case User.new(user_id, password) do
      {:ok, user} ->
        {:ok, user}

      {:error, %{errors: [id: {error_message, _}]}} ->
        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:invalid_username, error_message))

      {:error, %{errors: [pwd_hash: {"password is too weak", _}]}} ->
        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:weak_password, Credentials.weak_password_message()))

      {:error, changeset} ->
        Logger.error("Error creating a user during registration: #{inspect(changeset.errors)}")

        conn
        |> put_status(500)
        |> json(Errors.unknown())
    end
  end

  defp authenticate_by_refresh_token(conn, _) do
    %{"refresh_token" => refresh_token} = conn.assigns.request

    case Auth.by(:refresh, refresh_token) do
      {:ok, user, device} ->
        conn
        |> assign(:user, user)
        |> assign(:device, device)

      {:error, :expired} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", true)) |> halt()

      {:error, :unknown_token} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", false)) |> halt()

      {:error, error} ->
        Logger.error(
          "A fatal error occurred trying to fetch user/device records for refresh authentication: #{inspect(error)}"
        )

        conn |> put_status(500) |> json(Errors.unknown()) |> halt()
    end
  end
end
