defmodule RadioBeamWeb.RoomController do
  use RadioBeamWeb, :controller

  require Logger

  alias RadioBeam.{Errors, Room, User}
  alias RadioBeamWeb.Schemas.Room, as: RoomSchema

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, [get_schema: {RoomSchema, :create, []}] when action == :create

  def create(conn, _params) do
    %User{} = creator = conn.assigns.user
    request = conn.assigns.request

    {%{"room_version" => room_version, "creation_content" => create_content}, params} =
      request |> Map.put_new("creation_content", %{}) |> Map.split(["room_version", "creation_content"])

    opts =
      Enum.reduce(params, [], fn
        {"initial_state", state_events}, acc -> Keyword.put(acc, :addl_state_events, state_events)
        {"is_direct", direct?}, acc -> Keyword.put(acc, :direct?, direct?)
        {"power_level_content_override", pls}, acc -> Keyword.put(acc, :power_levels, pls)
        {"room_alias_name", room_alias}, acc -> Keyword.put(acc, :alias, room_alias.opaque_id)
        {"visibility", visibility}, acc -> Keyword.put(acc, :visibility, visibility)
        {key, value}, acc -> [{String.to_existing_atom(key), value} | acc]
      end)

    case Room.create(room_version, creator, create_content, opts) do
      {:ok, room_id} ->
        json(conn, %{room_id: room_id})

      {:error, :invalid_state} ->
        Logger.info("not creating room, provided params did not pass auth checks")

        conn
        |> put_status(400)
        |> json(
          Errors.endpoint_error(
            :invalid_room_state,
            "The events generated from your request did not pass authentication checks"
          )
        )

      {:error, :alias_in_use} ->
        Logger.info("not creating room, alias in use")

        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:room_in_use, "The provided room alias is already being used for another room"))

      {:error, reason} ->
        Logger.error("error creating room from /createRoom: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> json(Errors.endpoint_error(:invalid_room_state, "The provided initial state is invalid."))
    end
  end

  def joined(conn, _params), do: json(conn, %{joined_rooms: Room.joined(conn.assigns.user.id)})
end
