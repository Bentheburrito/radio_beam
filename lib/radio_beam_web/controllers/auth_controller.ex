defmodule RadioBeamWeb.AuthController do
  use RadioBeamWeb, :controller

  alias RadioBeam.Credentials
  alias RadioBeam.Errors
  alias RadioBeam.User
  alias RadioBeam.User.Auth
  alias RadioBeam.User.Device

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: RadioBeamWeb.Schemas.Auth] when action in [:register, :login, :refresh]
  plug RadioBeamWeb.Plugs.Authenticate when action == :whoami

  def register(%{params: %{"kind" => "guest"}} = conn, _params),
    do: conn |> put_status(403) |> json(Errors.unrecognized("This homeserver does not support guest users."))

  def register(%{params: %{"kind" => kind}} = conn, _params) when kind != "user",
    do: conn |> put_status(403) |> json(Errors.bad_json("Expected 'user' or 'guest' as the kind, got '#{kind}'"))

  def register(conn, _params) do
    %{"username" => {_version, localpart}, "password" => pwd, "inhibit_login" => inhibit_login?} = conn.assigns.request

    case Auth.register(localpart, pwd) do
      {:ok, %User{} = user} ->
        if inhibit_login? do
          json(conn, %{user_id: user.id})
        else
          %{"device_id" => device_id, "initial_device_display_name" => display_name} = conn.assigns.request

          {:ok, user, device} = Auth.password_login(user.id, pwd, device_id, display_name)
          json(conn, Auth.session_info(user, device))
        end

      {:error, :already_exists} ->
        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:user_in_use, "That username is already taken."))

      {:error, :registration_disabled} ->
        conn
        |> put_status(403)
        |> json(Errors.forbidden("Registration is not enabled on this homeserver."))
        |> halt()

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

  def login(conn, _params) do
    user_id =
      case conn.assigns.request["identifier"]["user"] do
        {_version, localpart} -> "@#{localpart}:#{RadioBeam.server_name()}"
        "@" <> _ = user_id -> user_id
      end

    %{"device_id" => device_id, "initial_device_display_name" => display_name, "password" => pwd} = conn.assigns.request

    case Auth.password_login(user_id, pwd, device_id, display_name) do
      {:ok, user, device} ->
        json(conn, Auth.session_info(user, device))

      {:error, :unknown_user_or_pwd} ->
        conn |> put_status(403) |> json(Errors.forbidden("Unknown username or password"))
    end
  end

  def refresh(conn, _params) do
    %{"refresh_token" => refresh_token} = conn.assigns.request

    case Auth.refresh(refresh_token) do
      {:ok, %Device{} = device} ->
        json(conn, %{
          access_token: device.access_token,
          refresh_token: device.refresh_token,
          expires_in_ms: DateTime.diff(device.expires_at, DateTime.utc_now(), :millisecond)
        })

      {:error, :not_found} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", false))

      {:error, :expired} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", true)) |> halt()

      {:error, :unknown_token} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", false)) |> halt()

      # TODO: should add config to expire refresh tokens after X time. 
      # Currently, refresh tokens never expire, so it just lives forever unless
      # the device is destroyed from another session. Would also allow us to 
      # support soft-logout here

      {:error, error} ->
        Logger.error("Got error trying to use a refresh token: #{inspect(error)}")
        conn |> put_status(401) |> json(Errors.unknown())
    end
  end

  # TOIMPL: application service users
  def whoami(conn, _params) do
    json(conn, %{
      device_id: conn.assigns.device.id,
      is_guest: false,
      user_id: conn.assigns.user.id
    })
  end
end
