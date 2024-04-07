defmodule RadioBeamWeb.LoginController do
  use RadioBeamWeb, :controller

  require Logger

  alias RadioBeam.{Device, Errors, Repo, User}

  # TODO: m.login.token
  plug RadioBeamWeb.Plugs.EnsureFieldIn, path: ["type"], values: ["m.login.password"]
  plug :identify
  plug :verify_password_or_token

  def login(conn, params) do
    device_id = Map.get_lazy(params, "device_id", &Device.generate_token/0)
    user = conn.assigns.user

    device_params =
      case Repo.get(Device, device_id) do
        {:ok, nil} ->
          %{
            id: device_id,
            user_id: user.id,
            display_name: Map.get(params, "initial_device_display_name", Device.default_device_name()),
            access_token: Device.generate_token(),
            refresh_token: Device.generate_token()
          }

        {:ok, %Device{} = device} ->
          %{
            id: device.id,
            user_id: device.user_id,
            display_name: device.display_name,
            access_token: Device.generate_token(),
            refresh_token: Device.generate_token()
          }
      end

    case Device.new(device_params) do
      {:ok, device} ->
        # this will overwrite any existing device with the same `:id` in the 
        # table, invalidating previous tokens.
        Repo.insert!(device)

        json(conn, %{
          device_id: device.id,
          access_token: device.access_token,
          refresh_token: device.refresh_token,
          expires_in_ms: DateTime.diff(device.expires_at, DateTime.utc_now(), :millisecond),
          user_id: device.user_id
        })

      {:error, changeset} ->
        # TODO? register uses this, and maybe we should delete the user and 
        # have them restart the registration process
        Logger.error("Error creating user #{user.id}'s device during login: #{inspect(changeset)}")

        conn
        |> put_status(500)
        |> json(Errors.unknown("Error creating device for user #{user.id}. Please try again."))
    end
  end

  defp identify(%{params: %{"identifier" => %{"type" => "m.id.user", "user" => localpart_or_id}}} = conn, _) do
    user_id =
      if String.starts_with?(localpart_or_id, "@") do
        localpart_or_id
      else
        server_name = Application.fetch_env!(:radio_beam, :server_name)
        "@#{localpart_or_id}:#{server_name}"
      end

    case Repo.get(User, user_id) do
      {:ok, nil} ->
        conn
        |> put_status(403)
        |> json(Errors.forbidden(unknown_user_or_pwd()))
        |> halt()

      {:ok, %User{} = user} ->
        assign(conn, :user, user)
    end
  end

  defp identify(conn, _) do
    conn
    |> put_status(400)
    |> json(Errors.bad_json("Unrecognized or missing 'identifier': '#{Jason.encode!(conn.params["identifier"])}"))
    |> halt()
  end

  defp verify_password_or_token(%{params: %{"password" => password}} = conn, _) do
    if Argon2.verify_pass(password, conn.assigns.user.pwd_hash) do
      conn
    else
      conn
      |> put_status(403)
      |> json(Errors.forbidden(unknown_user_or_pwd()))
      |> halt()
    end
  end

  defp unknown_user_or_pwd, do: "Unknown username or password"
end
