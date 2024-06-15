defmodule RadioBeamWeb.RoomController do
  use RadioBeamWeb, :controller

  require Logger

  alias Polyjuice.Util.Schema
  alias RadioBeam.{Errors, Room, User}

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, get_schema: {__MODULE__, :schema, []}

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

  def schema() do
    %{available: available_room_versions, default: default_room_version} =
      Application.get_env(:radio_beam, :capabilities)[:"m.room_versions"]

    %{
      "creation_content" => optional(content_schema()),
      "initial_state" => optional(:any),
      "invite" => optional(:any),
      "invite_3pid" => optional(:any),
      "is_direct" => optional(:boolean),
      "name" => optional(:string),
      "power_level_content_override" => [:any, default: %{}],
      "preset" =>
        optional(
          Schema.enum(%{
            "private_chat" => :private_chat,
            "public_chat" => :public_chat,
            "trusted_private_chat" => :trusted_private_chat
          })
        ),
      "room_alias_name" => optional(&room_localpart/1),
      "room_version" => [Schema.enum(Map.keys(available_room_versions)), default: default_room_version],
      "topic" => optional(:string),
      "visibility" => [Schema.enum(%{"private" => :private, "public" => :public}), default: :private]
    }
  end

  defp content_schema() do
    %{
      "m.federate" => [:boolean, default: true],
      "predecessor" => optional(&Schema.room_id/1),
      "type" => optional(:string),
      # these will just be overwritten
      "room_version" => optional(:any),
      "creator" => optional(:any)
    }

    # case Integer.parse(room_version) do
    #   {version_num, ""} when version_num in 1..10 -> Map.put(schema, "creator", &Schema.user_id/1)
    #   _ -> schema
    # end
  end

  # TODO: validate localpart grammar
  defp room_localpart(localpart) do
    Schema.room_alias("##{localpart}:#{RadioBeam.server_name()}")
  end

  defp optional(type), do: [type, :optional]
end
