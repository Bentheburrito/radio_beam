defmodule RadioBeamWeb.Plugs.EnsureFieldIn do
  @moduledoc """
  Ensures the value under the given `:path` in the request body is a member of 
  the given `:values`
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias RadioBeam.Errors

  def init(default), do: default

  def call(conn, opts) do
    path = Keyword.fetch!(opts, :path)
    values = Keyword.fetch!(opts, :values)

    val = get_in(conn.params, path)

    if val in values do
      conn
    else
      error =
        Errors.bad_json(
          "Expected key '#{Enum.join(path, ".")}' to be one of #{Enum.map_join(values, ", ", &"'#{&1}'")}. Got '#{inspect(val)}'"
        )

      conn |> put_status(400) |> json(error) |> halt()
    end
  end
end
