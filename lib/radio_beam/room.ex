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
  alias RadioBeam.Room
  alias RadioBeam.Room.Ops
  alias RadioBeam.Room.Utils
  alias RadioBeam.RoomSupervisor
  alias RadioBeam.User

  @type t() :: %__MODULE__{}

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

  @spec invite(room_id :: String.t(), inviter_id :: String.t(), invitee_id :: String.t()) ::
          :ok | {:error, :unauthorized | :room_does_not_exist | :internal}
  def invite(room_id, inviter_id, invitee_id) do
    call_if_alive(room_id, {:invite, inviter_id, invitee_id})
  end

  ### IMPL ###

  @impl GenServer
  def init({room_id, events_or_room}) do
    case events_or_room do
      [%{"type" => "m.room.create", "content" => %{"room_version" => version}} | _] = events ->
        case Ops.put_events(%Room{id: room_id, depth: 0, latest_event_ids: [], state: %{}, version: version}, events) do
          {:ok, %Room{}} = result -> result
          {:error, :unauthorized} -> {:stop, :invalid_state}
          {:error, %Ecto.Changeset{} = changeset} -> {:stop, inspect(changeset.errors)}
          {:error, {:transaction_aborted, reason}} -> {:stop, reason}
          {:error, error} -> {:stop, inspect(error)}
        end

      %Room{} = room ->
        {:ok, room}

      invalid_init_arg ->
        reason = "Tried to start a Room with invalid arg: #{inspect(invalid_init_arg)}"
        Logger.error("Aborting room #{room_id} GenServer init: #{reason}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:invite, inviter_id, invitee_id}, _from, %Room{} = room) do
    event = Utils.membership_event(room.id, inviter_id, invitee_id, :invite)

    case Ops.put_events(room, [event]) do
      {:ok, room} ->
        {:reply, :ok, room}

      {:error, :unauthorized} = e ->
        {:reply, e, room}

      {:error, error} = e ->
        Logger.error("an error occurred trying to put a `Room.invite/3` event: #{inspect(error)}")
        {:reply, e, room}
    end
  end

  defp get(id) do
    Memento.transaction(fn -> Memento.Query.read(__MODULE__, id) end)
  end

  defp call_if_alive(room_id, message) do
    GenServer.call(via(room_id), message)
  catch
    :exit, {:noproc, _} -> {:error, :room_does_not_exist}
  end

  defp via(room_id), do: {:via, Registry, {RadioBeam.RoomRegistry, room_id}}
end
