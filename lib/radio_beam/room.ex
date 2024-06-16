defmodule RadioBeam.Room do
  @moduledoc """
  API for interacting with rooms. Every room is represented by a GenServer, 
  which is responsible for correctly applying events to a room. All actions 
  made against a room should be done through its GenServer by using this 
  module.
  """

  @types [
    id: :string,
    depth: :integer,
    latest_event_ids: {:array, :string},
    state: :map,
    version: :string
  ]
  @attrs Keyword.keys(@types)

  use Memento.Table,
    attributes: @attrs,
    type: :set

  use GenServer

  require Logger

  alias Polyjuice.Util.Identifiers.V1.RoomIdentifier
  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.Room.Utils
  alias RadioBeam.RoomAlias
  alias RadioBeam.RoomSupervisor
  alias RadioBeam.User

  @typep t() :: %__MODULE__{}

  ### API ###

  @typedoc """
  Additional options to configure a new room with.

  TODO: document overview of each variant here
  """
  @type create_opt ::
          {:power_levels, map()}
          | {:preset, :private_chat | :trusted_private_chat | :public_chat}
          | {:addl_state_events, [map()]}
          | {:alias | :name | :topic, String.t()}
          | {:invite | :invite_3pid, [String.t()]}
          | {:direct?, boolean()}
          | {:visibility, :public | :private}

  @doc """
  Create a new room with the given events. Returns `{:ok, room_id}` if the 
  room was successfully started.

  TODO: should probably take each type of event as an individual parameter, e.g.
  `create(create_event, power_level_event, …)`
  """
  @spec create(String.t(), User.t(), map(), [create_opt()]) :: {:ok, String.t()} | {:error, any()}
  def create(room_version, %User{} = creator, create_content \\ %{}, opts \\ []) do
    server_name = RadioBeam.server_name()
    room_id = server_name |> RoomIdentifier.generate() |> to_string()

    create_event = Utils.create_event(room_id, creator.id, room_version, create_content)
    creator_join_event = Utils.membership_event(room_id, creator.id, creator.id, :join)
    power_levels_event = Utils.power_levels_event(room_id, creator.id, Keyword.get(opts, :power_levels, %{}))

    wrapped_canonical_alias_event =
      case Keyword.get(opts, :alias) do
        nil -> []
        alias_localpart -> [Utils.canonical_alias_event(room_id, creator.id, alias_localpart, server_name)]
      end

    visibility = Keyword.get(opts, :visibility, :private)

    unless visibility in [:public, :private] do
      raise "option :visibility must be one of [:public, :private]"
    end

    preset = Keyword.get(opts, :preset, (visibility == :private && :private_chat) || :public_chat)

    unless preset in [:public_chat, :private_chat, :trusted_private_chat] do
      raise "option :preset must be one of [:public_chat, :private_chat, :trusted_private_chat]"
    end

    preset_events = Utils.state_events_from_preset(preset, room_id, creator.id)

    wrapped_name_event =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [Utils.name_event(room_id, creator.id, name)]
      end

    wrapped_topic_event =
      case Keyword.get(opts, :topic) do
        nil -> []
        topic -> [Utils.topic_event(room_id, creator.id, topic)]
      end

    invite_events =
      opts
      |> Keyword.get(:invite, [])
      |> Enum.map(&Utils.membership_event(room_id, creator.id, &1, :invite))

    # TOIMPL
    invite_3pid_events = []

    init_state_events =
      opts
      |> Keyword.get(:addl_state_events, [])
      |> Enum.map(&(&1 |> Map.put("room_id", room_id) |> Map.put("sender", creator.id)))

    events =
      [create_event, creator_join_event, power_levels_event] ++
        wrapped_canonical_alias_event ++
        preset_events ++
        init_state_events ++
        wrapped_name_event ++ wrapped_topic_event ++ invite_events ++ invite_3pid_events

    case DynamicSupervisor.start_child(RoomSupervisor, {__MODULE__, {room_id, events}}) do
      {:ok, _pid} -> {:ok, room_id}
      error -> error
    end
  end

  @doc """
  Starts the GenServer to process events for an existing room. Returns 
  `{:ok, room_id}` if the room was successfully started.
  """
  @spec revive(String.t()) :: {:ok, String.t()} | {:error, :room_does_not_exist | any()}
  def revive(room_id) do
    case get(room_id) do
      {:ok, %Room{} = room} ->
        case DynamicSupervisor.start_child(RoomSupervisor, {__MODULE__, {room.id, room}}) do
          {:ok, _pid} -> {:ok, room_id}
          error -> error
        end

      {:ok, nil} ->
        {:error, :room_does_not_exist}

      {:error, error} ->
        Logger.error("Error reviving #{room_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  def start_link({room_id, _events_or_room} = init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: via(room_id))
  end

  @spec joined(user_id :: String.t()) :: [room_id :: String.t()]
  def joined(user_id) do
    fn ->
      user_id
      |> :radio_beam_room_queries.joined()
      |> :qlc.e()
    end
    |> Memento.transaction()
    |> case do
      {:ok, room_ids} ->
        room_ids

      {:error, error} ->
        Logger.error("tried to list user #{inspect(user_id)}'s joined rooms, but got error: #{inspect(error)}")
        []
    end
  end

  ### IMPL ###

  @impl GenServer
  def init({room_id, events_or_room}) do
    case events_or_room do
      [%{"type" => "m.room.create", "content" => %{"room_version" => version}} | _] = events ->
        case apply_events(
               %Room{id: room_id, depth: 0, latest_event_ids: [], state: %{}, version: version},
               events
             ) do
          # TOIMPL: add room to published room list if visibility option was set to :public
          {%Room{} = room, pdus} ->
            fn ->
              addl_actions =
                for %PDU{} = pdu <- pdus, do: pdu |> Memento.Query.write() |> get_pdu_followup_actions()

              room = Memento.Query.write(room)

              addl_actions
              |> List.flatten()
              |> Stream.filter(&is_function(&1))
              |> Enum.find_value(room, fn action ->
                case action.() do
                  {:error, error} -> Memento.Transaction.abort(error)
                  _result -> false
                end
              end)
            end
            |> Memento.transaction()
            |> case do
              {:ok, %Room{}} = result -> result
              {:error, {:transaction_aborted, reason}} -> {:stop, reason}
              {:error, error} -> {:stop, error}
            end

          {:error, :unauthorized} ->
            {:stop, :invalid_state}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:stop, inspect(changeset.errors)}

          {:error, error} ->
            {:stop, inspect(error)}
        end

      %Room{} = room ->
        {:ok, room}

      invalid_init_arg ->
        reason = "Tried to start a Room with invalid arg: #{inspect(invalid_init_arg)}"
        Logger.error("Aborting room #{room_id} GenServer init: #{reason}")
        {:stop, reason}
    end
  end

  defp get_pdu_followup_actions(%PDU{type: "m.room.canonical_alias"} = pdu) do
    for room_alias <- [pdu.content["alias"] | Map.get(pdu.content, "alt_aliases", [])], not is_nil(room_alias) do
      fn -> RoomAlias.put(room_alias, pdu.room_id) end
    end
  end

  defp get_pdu_followup_actions(%PDU{}), do: nil

  defp get(id) do
    Memento.transaction(fn -> Memento.Query.read(__MODULE__, id) end)
  end

  @spec apply_events(t(), [map()]) :: t() | {:error, :unauthorized}
  defp apply_events(room, events) when is_list(events) do
    Enum.reduce_while(events, {room, []}, fn event, {%Room{} = room, pdus} ->
      auth_events = select_auth_events(event, room.state)

      with true <- authorized?(room, event, auth_events),
           {:ok, %Room{} = room, %PDU{} = pdu} <- update_room(room, event, auth_events) do
        {:cont, {room, [pdu | pdus]}}
      else
        false ->
          Logger.info("Rejecting unauthorized event:\n#{inspect(event)}")
          {:halt, {:error, :unauthorized}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp select_auth_events(event, state) do
    keys = [{"m.room.create", ""}, {"m.room.power_levels", ""}, {"m.room.member", event["sender"]}]

    keys =
      if event["type"] == "m.room.member" do
        # TODO: check if room version actually supports restricted rooms
        keys =
          if sk = Map.get(event["content"], "join_authorised_via_users_server"),
            do: [{"m.room.member", sk} | keys],
            else: keys

        cond do
          match?(%{"membership" => "invite", "third_party_invite" => _}, event["content"]) ->
            [
              {"m.room.member", event["state_key"]},
              {"m.room.join_rules", ""},
              {"m.room.third_party_invite", get_in(event, ~w[content third_party_invite signed token])} | keys
            ]

          event["content"]["membership"] in ~w[join invite] ->
            [{"m.room.member", event["state_key"]}, {"m.room.join_rules", ""} | keys]

          :else ->
            [{"m.room.member", event["state_key"]} | keys]
        end
      else
        keys
      end

    for key <- keys, is_map_key(state, key), do: state[key]
  end

  defp authorized?(%Room{} = room, event, auth_events) do
    RoomVersion.authorized?(room.version, event, room.state, auth_events)
  end

  defp update_room(room, event, auth_events) do
    pdu_attrs =
      event
      |> Map.put("auth_events", Enum.map(auth_events, & &1["event_id"]))
      # ??? why are there no docs on depth besides the PDU desc
      |> Map.put("depth", room.depth + 1)
      |> Map.put("prev_events", room.latest_event_ids)

    with {:ok, pdu} = PDU.new(pdu_attrs, room.version) do
      room =
        room
        |> Map.update!(:depth, &(&1 + 1))
        |> Map.replace!(:latest_event_ids, [pdu.event_id])
        |> update_room_state(Map.put(event, "event_id", pdu.event_id))

      {:ok, room, pdu}
    end
  end

  defp update_room_state(room, event) do
    if is_map_key(event, "state_key") do
      %Room{room | state: Map.put(room.state, {event["type"], event["state_key"]}, event)}
    else
      room
    end
  end

  defp via(room_id), do: {:via, Registry, {RadioBeam.RoomRegistry, room_id}}
end
