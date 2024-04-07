defmodule RadioBeamWeb.AuthController do
  use RadioBeamWeb, :controller

  alias RadioBeam.{Credentials, Device, Errors, Repo, User}

  require Logger

  plug :ensure_registration_enabled
  plug RadioBeamWeb.Plugs.EnsureRequired, paths: [["username"], ["password"]], error: :missing_param
  plug :ensure_user_no_exists

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
end
