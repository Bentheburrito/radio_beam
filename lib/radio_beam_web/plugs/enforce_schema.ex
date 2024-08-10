defmodule RadioBeamWeb.Plugs.EnforceSchema do
  @moduledoc """
  Enforces the given Polyjuice schema against the request body

  Caller should set the `mod` option to the module with the Schema function(s).
  By default, the function with the same name as the Phoenix action will be
  invoked to get the schema. However, you can also use the `:fun` option to
  explcitly pass the function name.

  Additionally, if the `with_params?` option is set to `true`, the request
  params will be passed to the schema function.

  ```elixir
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: __MODULE__, fun: :schema
  ```
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  alias Polyjuice.Util.Schema
  alias RadioBeam.Errors

  def init(default), do: default

  def call(%Plug.Conn{} = conn, opts) do
    module = Keyword.fetch!(opts, :mod)
    function = Keyword.get_lazy(opts, :fun, fn -> Map.get(conn.private, :phoenix_action, :schema) end)
    args = if Keyword.get(opts, :with_params?, false), do: [conn.params], else: []

    schema = apply(module, function, args)

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

      {:error, :invalid_value, field_path, {:error, :no_match}} ->
        error(conn, "Could not match #{Enum.join(field_path, ".")}")

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
