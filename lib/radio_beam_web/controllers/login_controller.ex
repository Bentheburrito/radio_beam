defmodule RadioBeamWeb.LoginController do
  use RadioBeamWeb, :controller

  require Logger

  alias Polyjuice.Util.Schema
  alias RadioBeam.{Device, Errors, User}
  alias RadioBeam.User.Auth

  plug RadioBeamWeb.Plugs.EnforceSchema, mod: __MODULE__, fun: :schema
  plug :identify
  # TOIMPL: m.login.token
  plug :verify_password_or_token

  # TODO: revisit this and impl the whole schema
  def schema do
    %{"type" => Schema.enum(["m.login.password"])}
  end

  def login(conn, params) do
    device_id = Map.get_lazy(params, "device_id", &Device.generate_token/0)
    display_name = Map.get(params, "initial_device_display_name", Device.default_device_name())
    user = conn.assigns.user

    case Auth.login(user.id, device_id, display_name) do
      {:ok, auth_info} ->
        json(conn, Map.merge(auth_info, %{device_id: device_id, user_id: user.id}))

      {:error, _error} ->
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

    case User.get(user_id) do
      {:error, :not_found} ->
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
