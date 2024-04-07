defmodule RadioBeamWeb.Plugs.Authenticate do
  @moduledoc """
  Requires and authenticates the `access_token` included in the request.
  """
  import Plug.Conn

  def init(default), do: default

  def call(%{params: %{"access_token" => access_token}} = conn, _opts) do
    # TODO
  end
end
