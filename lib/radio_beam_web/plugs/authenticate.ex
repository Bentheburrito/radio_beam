defmodule RadioBeamWeb.Plugs.Authenticate do
  @moduledoc """
  Requires and authenticates the `access_token` included in the request.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias RadioBeam.Errors
  alias RadioBeam.User.Auth

  require Logger

  def init(default), do: default

  def call(%{assigns: %{access_token: access_token}} = conn, _opts) do
    case Auth.by(:access, access_token) do
      {:ok, user, device} ->
        conn
        |> assign(:user, user)
        |> assign(:device, device)

      {:error, :expired} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", true)) |> halt()

      {:error, :unknown_token} ->
        conn |> put_status(401) |> json(Errors.unknown_token("Unknown token", false)) |> halt()

      {:error, error} ->
        Logger.error("A fatal error occurred trying to fetch user/device records for authentication: #{inspect(error)}")
        conn |> put_status(500) |> json(Errors.unknown()) |> halt()
    end
  end

  def call(conn, opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        conn |> assign(:access_token, token) |> call(opts)

      _ ->
        case fetch_query_params(conn) do
          %{query_params: %{"access_token" => token}} ->
            conn |> assign(:access_token, token) |> call(opts)

          _ ->
            conn |> put_status(401) |> json(Errors.missing_token()) |> halt()
        end
    end
  end
end
