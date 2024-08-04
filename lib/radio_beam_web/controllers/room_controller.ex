defmodule RadioBeamWeb.RoomController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2, handle_common_error: 3]

  require Logger

  alias RadioBeam.{Errors, Room, Transaction, User}
  alias RadioBeamWeb.Schemas.Room, as: RoomSchema

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: RoomSchema] when action in [:create, :invite, :join, :get_nearest_event]
  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: RoomSchema, with_params?: true] when action == :send

  @missing_req_param_msg "Your request is missing one or more required parameters"

  def create(conn, _params) do
    %User{} = creator = conn.assigns.user
    request = conn.assigns.request

    opts =
      Enum.reduce(request, [], fn
        {"initial_state", state_events}, acc -> Keyword.put(acc, :addl_state_events, state_events)
        {"is_direct", direct?}, acc -> Keyword.put(acc, :direct?, direct?)
        {"power_level_content_override", pls}, acc -> Keyword.put(acc, :power_levels, pls)
        {"room_alias_name", room_alias}, acc -> Keyword.put(acc, :alias, room_alias.opaque_id)
        {"creation_content", content}, acc -> Keyword.put(acc, :content, content)
        {"version", version}, acc -> Keyword.put(acc, :version, version)
        {"visibility", visibility}, acc -> Keyword.put(acc, :visibility, visibility)
        {key, value}, acc -> [{String.to_existing_atom(key), value} | acc]
      end)

    case Room.create(creator, opts) do
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

    with {:ok, _event_id} <- Room.invite(room_id, inviter.id, invitee_id, request["reason"]) do
      json(conn, %{})
    else
      {:error, error} ->
        handle_common_error(
          conn,
          error,
          "Failed to invite: you either aren't in the room with permission to invite others, or the invitee is banned from the room"
        )
    end
  end

  # TOIMPL: server_name query parameter?
  def join(conn, %{"room_id_or_alias" => room_id_or_alias}) do
    if String.starts_with?(room_id_or_alias, "#") do
      case Room.Alias.to_room_id(room_id_or_alias) do
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

    with {:ok, _event_id} <- Room.join(room_id, joiner.id, request["reason"]) do
      json(conn, %{room_id: room_id})
    else
      {:error, error} -> handle_common_error(conn, error, "You need to be invited by a member of this room to join")
    end
  end

  def send(conn, %{"room_id" => room_id, "event_type" => event_type, "transaction_id" => txn_id}) do
    %User{} = sender = conn.assigns.user
    content = conn.assigns.request
    device_id = conn.assigns.device_id

    with {:ok, handle} <- Transaction.begin(txn_id, device_id, conn.request_path),
         {:ok, event_id} <- Room.send(room_id, sender.id, event_type, content) do
      response = %{event_id: event_id}

      Transaction.done(handle, response)
      json(conn, response)
    else
      {:already_done, response} ->
        json(conn, response)

      {:error, error} ->
        handle_common_error(conn, error)
    end
  end

  def send(conn, _params) do
    conn
    |> put_status(400)
    |> json(Errors.endpoint_error(:missing_param, @missing_req_param_msg))
  end

  def put_state(conn, %{"room_id" => room_id, "event_type" => event_type, "state_key" => state_key}) do
    %User{} = sender = conn.assigns.user
    content = conn.assigns.request

    with {:ok, event_id} <- Room.put_state(room_id, sender.id, event_type, state_key, content) do
      json(conn, %{event_id: event_id})
    else
      {:error, error} -> handle_common_error(conn, error)
    end
  end

  def put_state(conn, %{"room_id" => _, "event_type" => _} = params) do
    put_state(conn, Map.put(params, "state_key", ""))
  end

  def put_state(conn, _params) do
    conn
    |> put_status(400)
    |> json(Errors.endpoint_error(:missing_param, @missing_req_param_msg))
  end

  def get_event(conn, %{"room_id" => room_id, "event_id" => event_id}) do
    case Room.get_event(room_id, conn.assigns.user.id, event_id) do
      {:ok, event} -> json(conn, event)
      {:error, error} -> handle_common_error(conn, error)
    end
  end

  def get_event(conn, _params) do
    conn
    |> put_status(400)
    |> json(Errors.endpoint_error(:missing_param, @missing_req_param_msg))
  end

  # omg...
  @room_member_keys ["avatar_url", "displayname", "display_name"]
  def get_joined_members(conn, %{"room_id" => room_id}) do
    case Room.get_members(room_id, conn.assigns.user.id, :current, &(&1 == "join")) do
      {:ok, members} ->
        json(conn, %{joined: Map.new(members, &{&1["state_key"], Map.take(&1["content"], @room_member_keys)})})

      {:error, error} ->
        handle_common_error(conn, error)
    end
  end

  def get_members(conn, %{"room_id" => room_id} = params) do
    at_event_id =
      case params do
        %{"at" => prev_batch} -> prev_batch |> String.split("|") |> hd()
        _ -> :current
      end

    membership_filter_fn =
      case params do
        %{"membership" => to_include} ->
          fn membership ->
            to_exclude = Map.get(params, "not_membership", membership)
            membership == to_include or membership != to_exclude
          end

        %{"not_membership" => to_exclude} ->
          fn membership -> membership != to_exclude end

        _ ->
          fn _ -> true end
      end

    case Room.get_members(room_id, conn.assigns.user.id, at_event_id, membership_filter_fn) do
      {:ok, members} -> json(conn, %{chunk: members})
      {:error, error} -> handle_common_error(conn, error)
    end
  end

  def get_state(conn, %{"room_id" => room_id}) do
    case Room.get_state(room_id, conn.assigns.user.id) do
      {:ok, members} -> json(conn, Map.values(members))
      {:error, error} -> handle_common_error(conn, error)
    end
  end

  def get_state_event(conn, %{"room_id" => room_id, "event_type" => type, "state_key" => state_key}) do
    case Room.get_state(room_id, conn.assigns.user.id, type, state_key) do
      {:ok, event} -> json(conn, Map.get(event, "content", %{}))
      {:error, error} -> handle_common_error(conn, error)
    end
  end

  def get_state_event(conn, _params) do
    conn
    |> put_status(400)
    |> json(Errors.endpoint_error(:missing_param, @missing_req_param_msg))
  end

  def get_nearest_event(conn, %{"room_id" => room_id}) do
    %{"dir" => dir, "ts" => timestamp} = conn.assigns.request

    case Room.get_nearest_event(room_id, conn.assigns.user.id, dir, timestamp) do
      {:ok, pdu} -> json(conn, %{"event_id" => pdu.event_id, "origin_server_ts" => pdu.origin_server_ts})
      :none -> handle_common_error(conn, :not_found)
      {:error, error} -> handle_common_error(conn, error)
    end
  end

  def get_nearest_event(conn, _params) do
    conn
    |> put_status(400)
    |> json(Errors.endpoint_error(:missing_param, @missing_req_param_msg))
  end
end
