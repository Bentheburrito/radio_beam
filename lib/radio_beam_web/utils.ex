defmodule RadioBeamWeb.Utils do
  @moduledoc """
  Helper functions to use across controllers
  """
  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias RadioBeam.Errors

  @dup_annotation_msg "You already reacted with that"

  def handle_common_error(conn, error, unauth_message \\ "You do not have permission to perform that action") do
    {status, error_body} =
      case error do
        :unauthorized -> {403, Errors.forbidden(unauth_message)}
        :room_does_not_exist -> {404, Errors.not_found("Room not found")}
        :not_found -> {404, Errors.not_found("Resource not found")}
        :internal -> {500, Errors.unknown("An internal error occurred. Please try again")}
        :duplicate_annotation -> {400, Errors.endpoint_error(:duplicate_annotation, @dup_annotation_msg)}
      end

    conn
    |> put_status(status)
    |> json(error_body)
  end

  def json_error(conn, status, errors_fxn_name, arg_or_args \\ [])

  def json_error(conn, status, errors_fxn_name, args) when is_list(args) do
    conn
    |> put_status(status)
    |> json(apply(Errors, errors_fxn_name, args))
  end

  def json_error(conn, status, errors_fxn_name, arg), do: json_error(conn, status, errors_fxn_name, [arg])

  def halting_json_error(conn, status, errors_fxn_name, arg_or_args \\ []) do
    conn
    |> json_error(status, errors_fxn_name, arg_or_args)
    |> halt()
  end

  def rl(rl), do: [assigns: %{rate_limit: rl}]

  def ip_tuple_to_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end
