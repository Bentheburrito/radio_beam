defmodule RadioBeamWeb.FilterController do
  use RadioBeamWeb, :controller

  require Logger

  alias RadioBeam.Errors
  alias RadioBeam.Room.Timeline.Filter
  alias RadioBeamWeb.Schemas.Filter, as: FilterSchema

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, [get_schema: {FilterSchema, :filter, []}] when action == :put

  def put(%{assigns: %{user: %{id: user_id}}} = conn, %{"user_id" => user_id}) do
    request = conn.assigns.request

    case Filter.put(user_id, request) do
      {:ok, filter_id} ->
        json(conn, %{filter_id: filter_id})

      {:error, error} ->
        Logger.error("Error trying to put a new filter for #{user_id}: #{inspect(error)}")

        conn |> put_status(500) |> json(Errors.unknown("An unknown error occurred, please try again"))
    end
  end

  def put(conn, _params) do
    conn |> put_status(403) |> json(Errors.forbidden("You are not that user"))
  end
end
