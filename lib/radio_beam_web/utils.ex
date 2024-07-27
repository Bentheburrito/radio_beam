defmodule RadioBeamWeb.Utils do
  @moduledoc """
  Helper functions to use across controllers
  """
  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias RadioBeam.Errors

  def handle_common_error(conn, error, unauth_message \\ "You do not have permission to perform that action") do
    {status, error_body} =
      case error do
        :unauthorized -> {403, Errors.forbidden(unauth_message)}
        :room_does_not_exist -> {404, Errors.not_found("Room not found")}
        :not_found -> {404, Errors.not_found("Resource not found")}
        :internal -> {500, Errors.unknown("An internal error occurred. Please try again")}
      end

    conn
    |> put_status(status)
    |> json(error_body)
  end
end
