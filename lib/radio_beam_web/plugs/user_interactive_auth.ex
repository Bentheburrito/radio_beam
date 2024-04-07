defmodule RadioBeamWeb.Plugs.UserInteractiveAuth do
  @moduledoc """
  Plug for handling requests to the [User-Interactive Authentication REST API](https://spec.matrix.org/latest/client-server-api/#user-interactive-authentication-api).

  will impl this later alongside RadioBeam.UserInteractiveAuth later when more
  than standard username/password registration/login support is added
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(default), do: default

  def call(%{params: %{"auth" => _auth}} = _conn, _opts) do
  end

  def call(conn, opts) do
    flows = Keyword.fetch!(opts, :flows)
    params = Keyword.get(opts, :params, %{})
    session = 32 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn |> put_status(401) |> json(std_resp_body(flows, params, session))
  end

  defp std_resp_body(flows, params, session, add_fields \\ %{}) do
    Map.merge(
      %{
        flows: Enum.map(flows, &%{stages: &1}),
        params: params,
        session: session
      },
      add_fields
    )
  end
end
