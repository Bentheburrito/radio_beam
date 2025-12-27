defmodule RadioBeamWeb.LegacyAuthAPIController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 4]

  alias RadioBeam.Errors
  alias RadioBeam.User
  alias RadioBeam.User.Authentication.LegacyAPI

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema,
       [mod: RadioBeamWeb.Schemas.LegacyAuthAPI] when action in [:register, :login, :refresh]

  def register(%{params: %{"kind" => "guest"}} = conn, _params),
    do: json_error(conn, 403, :unrecognized, "This homeserver does not support guest users.")

  def register(%{params: %{"kind" => kind}} = conn, _params) when kind != "user",
    do: json_error(conn, 403, :bad_json, "Expected 'user' or 'guest' as the kind, got '#{kind}'")

  def register(conn, _params) do
    %{"username" => {_version, localpart}, "password" => pwd, "inhibit_login" => inhibit_login?} = conn.assigns.request

    case LegacyAPI.register(localpart, pwd) do
      {:ok, %User{} = user} ->
        if inhibit_login? do
          json(conn, %{user_id: user.id})
        else
          device_id = Map.get_lazy(conn.assigns.request, "device_id", &LegacyAPI.generate_device_id/0)
          display_name = Map.fetch!(conn.assigns.request, "initial_device_display_name")

          {:ok, access_token, refresh_token, _scope, expires_in} =
            LegacyAPI.password_login(user.id, pwd, device_id, display_name)

          json(conn, %{
            device_id: device_id,
            user_id: user.id,
            access_token: access_token,
            refresh_token: refresh_token,
            expires_in_ms: expires_in
          })
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

      {:error, [user_id: error_message]} ->
        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:invalid_username, error_message))

      {:error, [pwd_hash: "password is too weak"]} ->
        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:weak_password, LegacyAPI.weak_password_message()))

      {:error, errors} ->
        Logger.error("Error creating a user during registration: #{inspect(errors)}")

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

    %{"initial_device_display_name" => display_name, "password" => pwd} = conn.assigns.request
    device_id = Map.get_lazy(conn.assigns.request, "device_id", &LegacyAPI.generate_device_id/0)

    case LegacyAPI.password_login(user_id, pwd, device_id, display_name) do
      {:ok, access_token, refresh_token, _scope, expires_in} ->
        json(conn, %{
          device_id: device_id,
          user_id: user_id,
          access_token: access_token,
          refresh_token: refresh_token,
          expires_in_ms: expires_in
        })

      {:error, :unknown_user_or_pwd} ->
        conn |> put_status(403) |> json(Errors.forbidden("Unknown username or password"))
    end
  end

  def refresh(conn, _params) do
    %{"refresh_token" => refresh_token} = conn.assigns.request

    case LegacyAPI.refresh(refresh_token) do
      {:ok, access_token, refresh_token, _scope, expires_in} ->
        json(conn, %{
          access_token: access_token,
          refresh_token: refresh_token,
          expires_in_ms: expires_in
        })

      {:error, :not_found} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", false))

      {:error, :expired_token} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", true)) |> halt()

      {:error, :invalid_token} ->
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
end
