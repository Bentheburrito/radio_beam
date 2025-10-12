defmodule RadioBeamWeb.AccountController do
  use RadioBeamWeb, :controller

  require Logger

  alias RadioBeam.Errors
  alias RadioBeam.Room
  alias RadioBeam.User.Account

  plug RadioBeamWeb.Plugs.Authenticate

  def get_config(%{assigns: %{user: %{id: user_id}}} = conn, %{"user_id" => user_id, "type" => type} = params) do
    with {:ok, scope} <- parse_scope(Map.get(params, "room_id", :global)),
         nil <- get_in(conn.assigns.user.account_data, [scope, type]) do
      conn
      |> put_status(404)
      |> json(Errors.not_found("No '#{type}' #{scope} account data has been provided for this user"))
    else
      {:error, :invalid_room_id} ->
        conn |> put_status(400) |> json(Errors.endpoint_error(:invalid_param, "Not a valid room ID"))

      data ->
        json(conn, data)
    end
  end

  def get_config(conn, _params) do
    conn |> put_status(403) |> json(Errors.forbidden("You cannot get account data for other users"))
  end

  def put_config(%{assigns: %{user: %{id: user_id}}} = conn, %{"user_id" => user_id, "type" => type} = params) do
    with content when is_map(content) <- conn.body_params,
         {:ok, _} <- Account.put(user_id, Map.get(params, "room_id", :global), type, content) do
      json(conn, %{})
    else
      {:error, :invalid_room_id} ->
        conn |> put_status(400) |> json(Errors.endpoint_error(:invalid_param, "Not a valid room ID"))

      {:error, :invalid_type} ->
        conn |> put_status(405) |> json(Errors.bad_json("Cannot set #{type} through this API"))

      _bad_content ->
        conn |> put_status(400) |> json(Errors.bad_json("Request body must be JSON"))
    end
  end

  def put_config(conn, _params) do
    conn |> put_status(403) |> json(Errors.forbidden("You cannot put account data for other users"))
  end

  defp parse_scope(:global), do: {:ok, :global}

  defp parse_scope(room_id) do
    if Room.exists?(room_id), do: {:ok, room_id}, else: {:error, :invalid_room_id}
  end
end
