defmodule RadioBeamWeb.Plugs.RateLimit do
  @moduledoc """
  Rate limit a request. Backed by `RadioBeam.RateLimit` (see its documentation
  for more info).
  """
  import Plug.Conn
  import RadioBeamWeb.Utils, only: [json_error: 4]

  alias RadioBeam.RateLimit

  require Logger

  def init(default), do: default

  def call(%{assigns: %{rate_limit: %RateLimit{} = rate_limit}} = conn, _opts) do
    auth_info =
      case conn.assigns do
        %{session: %{user: %{id: user_id}, device: %{id: device_id}}} -> {user_id, device_id}
        %{} -> :not_authenticated
      end

    case RateLimit.check(conn.request_path, auth_info, conn.remote_ip, rate_limit) do
      {:allow, _} ->
        conn

      {:deny, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", "#{div(retry_after_ms, 1_000)}")
        |> json_error(429, :limit_exceeded, retry_after_ms)
        |> halt()
    end
  end
end
