defmodule RadioBeamWeb.AuthController do
  use RadioBeamWeb, :controller

  alias RadioBeam.{Credentials, Device, Errors, Repo, User}

  require Logger

  # TODO: convert this `with` into plugs?
  def register(conn, params) do
    with :ok <- verify_user_registration(conn, params),
         {:ok, username} <- required(conn, params, "username", missing_username()),
         {:ok, password} <- required(conn, params, "password", missing_password()),
         server_name = Application.fetch_env!(:radio_beam, :server_name),
         user_id = "@#{username}:#{server_name}",
         :ok <- ensure_no_exists(conn, user_id),
         {:ok, %User{} = user} <- new_user(conn, user_id, password) do
      res_body = %{home_server: server_name, user_id: user.id}

      Repo.insert!(user)

      if Map.get(params, "inhibit_login", false) do
        json(conn, res_body)
      else
        params = Map.put_new_lazy(params, "device_id", &Device.generate_token/0)

        conn
        |> assign(:user, user)
        |> RadioBeamWeb.LoginController.login(Map.take(params, ["device_id", "initial_device_display_name"]))
      end
    end
  end

  defp verify_user_registration(conn, params) do
    if Application.get_env(:radio_beam, :registration_enabled, false) do
      case Map.get(params, "kind", "user") do
        "user" ->
          :ok

        "guest" ->
          conn
          |> put_status(403)
          |> json(Errors.unrecognized("This homeserver does not support guest registration at this time."))

        other ->
          Logger.info("unknown `kind` during registration: #{inspect(other)}")

          conn
          |> put_status(403)
          |> json(Errors.bad_json("Expected 'user' or 'guest' as the kind, got '#{other}'"))
      end
    else
      conn
      |> put_status(403)
      |> json(Errors.forbidden("Registration is not enabled on this homeserver"))
    end
  end

  defp ensure_no_exists(conn, user_id) do
    case Repo.get(User, user_id) do
      {:ok, %User{}} ->
        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:user_in_use, "That username is already taken."))

      {:ok, nil} ->
        :ok
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

  defp required(conn, params, key, error) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> conn |> put_status(400) |> json(error)
    end
  end

  defp missing_username, do: Errors.endpoint_error(:missing_param, "Please provide a username.")
  defp missing_password, do: Errors.endpoint_error(:missing_param, "Please provide a password.")
end
