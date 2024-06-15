defmodule RadioBeamWeb.Plugs.Authenticate do
  @moduledoc """
  Requires and authenticates the `access_token` included in the request.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias RadioBeam.Device
  alias RadioBeam.Errors
  alias RadioBeam.Repo

  def init(default), do: default

  def call(%{assigns: %{access_token: access_token}} = conn, _opts) do
    with %Device{expires_at: expires_at} = device <- get_device(conn, access_token),
         :not_expired <- verify_not_expired(conn, expires_at) do
      case Repo.get(RadioBeam.User, device.user_id) do
        {:ok, nil} -> raise "The associated user for the authenticated device does not exist"
        {:ok, user} -> assign(conn, :user, user)
      end
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
            conn |> put_status(400) |> json(Errors.missing_token()) |> halt()
        end
    end
  end

  defp get_device(conn, access_token) do
    case Device.by_access_token(access_token) do
      {:ok, %Device{} = device} ->
        device

      {:error, :not_found} ->
        conn |> put_status(400) |> json(Errors.unknown_token()) |> halt()
    end
  end

  defp verify_not_expired(conn, expires_at) do
    case DateTime.compare(DateTime.utc_now(), expires_at) do
      :lt ->
        :not_expired

      _ ->
        conn |> put_status(400) |> json(Errors.unknown_token()) |> halt()
    end
  end
end
