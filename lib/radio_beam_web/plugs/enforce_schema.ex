defmodule RadioBeamWeb.Plugs.EnforceSchema do
  @moduledoc """
  Enforces the given Polyjuice schema against the request body

  Caller should set the `get_schema` option to an MFA tuple that returns the
  Polyjuice schema. e.g.

  ```elixir
  plug RadioBeamWeb.Plugs.EnforceSchema, get_schema: {__MODULE__, :schema, []}
  ```
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  alias Polyjuice.Util.Schema
  alias RadioBeam.Errors

  def init(default), do: default

  def call(%Plug.Conn{} = conn, get_schema: {m, f, a}) do
    schema = apply(m, f, a)

    case Schema.match(conn.params, schema) do
      {:ok, parsed} ->
        assign(conn, :request, parsed)

      {:error, :invalid_value, field_path, {:error, :wrong_type, expected_type, value}} ->
        error(conn, "#{Enum.join(field_path, ".")} needs to be a(n) #{expected_type}, got '#{inspect(value)}'")

      {:error, :invalid_value, field_path, {:error, :mismatch_regex, value}} ->
        error(conn, "#{Enum.join(field_path, ".")} is not a valid value, got '#{inspect(value)}'")

      {:error, :invalid_value, field_path, {:error, :invalid_enum_value, enum_values, value}} ->
        if List.last(field_path) == "room_version" do
          error(conn, "Room version not supported.", 400, &Errors.endpoint_error(:unsupported_room_version, &1))
        else
          error(
            conn,
            "#{Enum.join(field_path, ".")} needs to be one of #{Enum.join(enum_values, ", ")}. Got '#{inspect(value)}'"
          )
        end

      {:error, :invalid_value, field_path, {:error, error, value}} ->
        error(conn, "Could not parse #{Enum.join(field_path, ".")}: #{inspect(error)}, got '#{inspect(value)}'")

      {:error, :missing_value, field_path} ->
        error(conn, "#{Enum.join(field_path, ".")} is required but is not present")

      {:error, :invalid_pattern} ->
        Logger.error("The given schema/pattern is invalid: #{inspect(schema)}")
        error(conn, "An internal error has occurred", 500, &Errors.unknown/1)

      error ->
        Logger.error("Not handling an error returned by `Polyjuice.Util.Schema.match/2`: #{inspect(error)}")
        error(conn, "An internal error has occurred", 500, &Errors.unknown/1)
    end
  end

  defp error(conn, message, status \\ 400, error_fxn \\ &Errors.bad_json/1) do
    Logger.info("Plugs.EnforceSchema: #{message}")
    conn |> put_status(status) |> json(error_fxn.(message)) |> halt()
  end
end
