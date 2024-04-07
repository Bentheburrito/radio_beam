defmodule RadioBeamWeb.Plugs.EnsureRequired do
  @moduledoc """
  Ensures the list of given paths exist in the request body. Returns an error
  response if any are missing (defaults to `:bad_json`)
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias RadioBeam.Errors

  def init(default), do: default

  def call(conn, opts) do
    opts
    |> Keyword.fetch!(:paths)
    |> Enum.reduce_while(conn, fn path, conn ->
      case get_in(conn.params, path) do
        nil ->
          conn
          |> put_status(400)
          |> json(
            opts
            |> Keyword.get(:error, :bad_json)
            |> Errors.endpoint_error("Missing or `null` required param: '#{Enum.join(path, ".")}'")
          )
          |> then(&{:halt, &1})

        _present ->
          {:cont, conn}
      end
    end)
  end
end
