defmodule RadioBeamWeb.AccountController do
  use RadioBeamWeb, :controller

  require Logger

  alias RadioBeam.Errors
  alias RadioBeam.User

  def get_config(%{assigns: %{user_id: user_id}} = conn, %{"user_id" => user_id, "type" => type} = params) do
    scope = Map.get(params, "room_id", :global)

    with {:ok, account_data} <- User.get_account_data(user_id),
         data when not is_nil(data) <- get_in(account_data, [scope, type]) do
      json(conn, data)
    else
      _nil_or_not_found_tuple ->
        conn
        |> put_status(404)
        |> json(Errors.not_found("No '#{type}' #{scope} account data has been provided for this user"))
    end
  end

  def get_config(conn, _params) do
    conn |> put_status(403) |> json(Errors.forbidden("You cannot get account data for other users"))
  end

  def put_config(%{assigns: %{user_id: user_id}} = conn, %{"user_id" => user_id, "type" => type} = params) do
    with content when is_map(content) <- conn.body_params,
         :ok <- User.put_account_data(user_id, Map.get(params, "room_id", :global), type, content) do
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
end
