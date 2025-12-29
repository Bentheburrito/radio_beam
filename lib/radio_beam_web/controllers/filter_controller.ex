defmodule RadioBeamWeb.FilterController do
  use RadioBeamWeb, :controller

  require Logger

  alias RadioBeam.Errors
  alias RadioBeam.User
  alias RadioBeam.User.EventFilter
  alias RadioBeamWeb.Schemas.Filter, as: FilterSchema

  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: FilterSchema, fun: :filter] when action == :put

  def put(%{assigns: %{user_id: user_id}} = conn, %{"user_id" => user_id}) do
    case User.put_event_filter(user_id, conn.assigns.request) do
      {:ok, filter_id} ->
        json(conn, %{filter_id: filter_id})

      {:error, :not_found} ->
        Logger.error("Error :not_found occurred trying to put a new filter for #{user_id}")

        conn |> put_status(500) |> json(Errors.unknown("An unknown error occurred, please try again"))
    end
  end

  def put(conn, _params) do
    conn |> put_status(403) |> json(Errors.forbidden("You are not that user"))
  end

  def get(%{assigns: %{user_id: user_id}} = conn, %{"user_id" => user_id, "filter_id" => filter_id}) do
    case User.get_event_filter(user_id, filter_id) do
      {:ok, %EventFilter{} = filter} ->
        json(conn, filter.raw_definition)

      {:error, :not_found} ->
        conn |> put_status(404) |> json(Errors.not_found("Filter not found"))
    end
  end

  def get(conn, _params) do
    conn |> put_status(403) |> json(Errors.forbidden("A filter_id is required."))
  end
end
