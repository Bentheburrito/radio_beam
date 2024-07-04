defmodule RadioBeamWeb.RoomController do
  use RadioBeamWeb, :controller

  require Logger

  alias RadioBeam.{Errors, Room, RoomAlias, User}
  alias RadioBeamWeb.Schemas.Room, as: RoomSchema

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, [get_schema: {RoomSchema, :create, []}] when action == :create
  plug RadioBeamWeb.Plugs.EnforceSchema, [get_schema: {RoomSchema, :invite, []}] when action == :invite
  plug RadioBeamWeb.Plugs.EnforceSchema, [get_schema: {RoomSchema, :join, []}] when action == :join
  plug RadioBeamWeb.Plugs.EnforceSchema, [get_schema: {RoomSchema, :send, :params}] when action == :send

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

  def invite(conn, %{"room_id" => room_id}) do
    %User{} = inviter = conn.assigns.user
    request = conn.assigns.request
    invitee_id = to_string(Map.fetch!(request, "user_id"))

    case Room.invite(room_id, inviter.id, invitee_id, request["reason"]) do
      {:ok, _event_id} ->
        json(conn, %{})

      {:error, :unauthorized} ->
        conn
        |> put_status(403)
        |> json(
          Errors.forbidden(
            "Failed to invite: you either aren't in the room with permission to invite others, or the invitee is banned from the room"
          )
        )

      {:error, :room_does_not_exist} ->
        conn
        |> put_status(404)
        |> json(Errors.not_found("Room not found"))

      {:error, :internal} ->
        conn
        |> put_status(500)
        |> json(Errors.unknown("An internal error occurred. Please try again"))
    end
  end

  # TOIMPL: server_name query parameter?
  def join(conn, %{"room_id_or_alias" => room_id_or_alias}) do
    if String.starts_with?(room_id_or_alias, "#") do
      case RoomAlias.to_room_id(room_id_or_alias) do
        {:ok, room_id} ->
          join(conn, %{"room_id" => room_id})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(Errors.not_found("Room not found"))
      end
    else
      join(conn, %{"room_id" => room_id_or_alias})
    end
  end

  def join(conn, %{"room_id" => room_id}) do
    %User{} = joiner = conn.assigns.user
    request = conn.assigns.request

    case Room.join(room_id, joiner.id, request["reason"]) do
      {:ok, _event_id} ->
        json(conn, %{room_id: room_id})

      {:error, :unauthorized} ->
        conn
        |> put_status(403)
        |> json(Errors.forbidden("You do not have permission to join this room"))

      {:error, :room_does_not_exist} ->
        conn
        |> put_status(404)
        |> json(Errors.not_found("Room not found"))

      {:error, :internal} ->
        conn
        |> put_status(500)
        |> json(Errors.unknown("An internal error occurred. Please try again"))
    end
  end

  def send(conn, %{"room_id" => room_id, "event_type" => event_type, "transaction_id" => txn_id}) do
    %User{} = sender = conn.assigns.user
    request = conn.assigns.request

    with {:ok, event_id} <- Room.send(room_id, sender.id, event_type, request) do
      json(conn, %{event_id: event_id})
    else
      {:error, error} -> handle_room_call_error(conn, error)
    end
  end

  defp handle_room_call_error(conn, error) do
    {status, error_body} =
      case error do
        :unauthorized -> {403, Errors.forbidden("You do not have permission to perform that action")}
        :room_does_not_exist -> {404, Errors.not_found("Room not found")}
        :internal -> {500, Errors.unknown("An internal error occurred. Please try again")}
      end

    conn
    |> put_status(status)
    |> json(error_body)
  end
end
