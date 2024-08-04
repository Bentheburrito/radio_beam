defmodule RadioBeamWeb.AuthController do
  use RadioBeamWeb, :controller

  alias RadioBeam.User.Auth
  alias RadioBeam.{Credentials, Device, Errors, User}

  require Logger

  plug :ensure_registration_enabled when action == :register
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RadioBeamWeb.Schemas.Auth
  plug :authenticate_by_refresh_token when action == :refresh

  def register(conn, params) do
    %{"username" => {_version, localpart}, "password" => pwd} = conn.assigns.request

    with {:ok, %User{} = user} <- new_user(conn, localpart, pwd) do
      if Map.get(params, "inhibit_login", false) do
        json(conn, %{user_id: user.id})
      else
        device_id = Map.get_lazy(params, "device_id", &Device.generate_token/0)
        display_name = Map.get_lazy(params, "initial_device_display_name", &Device.default_device_name/0)

        {:ok, auth_info} = Auth.login(user.id, device_id, display_name)

        json(conn, Map.merge(auth_info, %{device_id: device_id, user_id: user.id}))
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

  defp new_user(conn, localpart, password) do
    server_name = Application.fetch_env!(:radio_beam, :server_name)
    user_id = "@#{localpart}:#{server_name}"

    with {:ok, user} <- User.new(user_id, password),
         :ok <- User.put_new(user) do
      {:ok, user}
    else
      {:error, :already_exists} ->
        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:user_in_use, "That username is already taken."))

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
