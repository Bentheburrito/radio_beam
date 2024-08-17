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

  alias :radio_beam_room_queries, as: Queries
  alias Polyjuice.Util.Identifiers.V1.RoomIdentifier
  alias RadioBeam.PDU
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
          | {:content, map()}
          | {:invite | :invite_3pid, [String.t()]}
          | {:direct?, boolean()}
          | {:version, String.t()}
          | {:visibility, :public | :private}

  # credo:disable-for-lines:75 Credo.Check.Refactor.CyclomaticComplexity
  @doc """
  Create a new room with the given options. Returns `{:ok, room_id}` if the 
  room was successfully started.
  """
  @spec create(User.t(), [create_opt()]) :: {:ok, String.t()} | {:error, any()}
  def create(%User{} = creator, opts \\ []) do
    server_name = RadioBeam.server_name()
    room_id = server_name |> RoomIdentifier.generate() |> to_string()

    room_version =
      Keyword.get_lazy(opts, :room_version, fn ->
        Application.get_env(:radio_beam, :capabilities)[:"m.room_versions"][:default]
      end)

    create_event = Utils.create_event(room_id, creator.id, room_version, Keyword.get(opts, :content, %{}))
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
  Starts the GenServer for an existing room. Returns `{:ok, room_id}` if the 
  room was successfully started.
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

  @doc "Returns all room IDs that `user_id` is joined to"
  @spec joined(user_id :: String.t()) :: [room_id :: String.t()]
  def joined(user_id) do
    fn ->
      user_id
      |> Queries.joined()
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

  @doc """
  Returns all rooms whose state has a `{m.room.member, user_id}` key
  """
  @spec all_where_has_membership(user_id :: String.t()) :: [room_id :: String.t()]
  def all_where_has_membership(user_id) do
    fn ->
      user_id
      |> Queries.has_membership()
      |> :qlc.e()
    end
    |> Memento.transaction()
    |> case do
      {:ok, room_ids} ->
        room_ids

      {:error, error} ->
        Logger.error("tried to list user #{inspect(user_id)}'s related rooms, but got error: #{inspect(error)}")

        []
    end
  end

  @doc "Tries to invite the invitee to the given room, if the inviter has perms"
  @spec invite(room_id :: String.t(), inviter_id :: String.t(), invitee_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def invite(room_id, inviter_id, invitee_id, reason \\ nil) do
    event = Utils.membership_event(room_id, inviter_id, invitee_id, :invite, reason)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc "Tries to join the given user to the given room"
  @spec join(room_id :: String.t(), joiner_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def join(room_id, joiner_id, reason \\ nil) do
    event = Utils.membership_event(room_id, joiner_id, joiner_id, :join, reason)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc "Tries to remove the given user from the given room"
  @spec leave(room_id :: String.t(), user_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def leave(room_id, user_id, reason \\ nil) do
    event = Utils.membership_event(room_id, user_id, user_id, :leave, reason)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc "Helper function to set the name of the room"
  @spec set_name(room_id :: String.t(), user_id :: String.t(), name :: String.t()) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def set_name(room_id, user_id, name) do
    event = Utils.name_event(room_id, user_id, name)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc """
  Sets the room state for the given type and state key. Other functions, when
  available, should be preferred to set the state of the room for specific 
  event types
  """
  @spec put_state(
          room_id :: String.t(),
          user_id :: String.t(),
          type :: String.t(),
          state_key :: String.t(),
          content :: String.t()
        ) ::
          {:ok, event_id :: String.t()}
          | {:error, :alias_in_use | :invalid_alias | :unauthorized | :room_does_not_exist | :internal}
  def put_state(room_id, user_id, type, state_key \\ "", content) do
    event = Utils.state_event(room_id, type, user_id, content, state_key)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc "Sends a Message Event to the room"
  @spec send(room_id :: String.t(), user_id :: String.t(), type :: String.t(), content :: String.t()) ::
          {:ok, event_id :: String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def send(room_id, user_id, type, content) do
    event = Utils.message_event(room_id, user_id, type, content)

    call_if_alive(room_id, {:put_event, event})
  end

  def get_event(room_id, user_id, event_id) do
    latest_joined_at_depth = users_latest_join_depth(room_id, user_id)

    PDU.get_if_visible_to_user(event_id, user_id, latest_joined_at_depth)
  end

  @doc """
  Returns the depth of the most recent event where the given user's membership
  is "join", or the atom `:currently_joined` if the user is currently in the
  room. The depth will be `-1` if the user was never in the room.
  """
  def users_latest_join_depth(room_id, user_id) do
    if call_if_alive(room_id, {:member?, user_id}) do
      :currently_joined
    else
      PDU.get_depth_of_users_latest_join(room_id, user_id)
    end
  end

  def get_members(room_id, user_id, at_event_id \\ :current, membership_filter \\ fn _ -> true end)

  def get_members(room_id, user_id, :current, membership_filter) do
    case get_state(room_id, user_id) do
      {:ok, state} -> get_members_from_state(state, membership_filter)
      error -> error
    end
  end

  def get_members(room_id, user_id, "$" <> _ = at_event_id, membership_filter) do
    latest_joined_at_depth = users_latest_join_depth(room_id, user_id)

    case PDU.get_if_visible_to_user(at_event_id, user_id, latest_joined_at_depth) do
      {:ok, %PDU{} = pdu} -> get_members_from_state(pdu.prev_state, membership_filter)
      _ -> {:error, :unauthorized}
    end
  end

  defp get_members_from_state(state, membership_filter) when is_map(state) do
    members =
      state
      |> Stream.map(&elem(&1, 1))
      |> Enum.filter(fn
        %{"type" => "m.room.member"} = event ->
          event |> get_in(["content", "membership"]) |> membership_filter.()

        _ ->
          false
      end)

    {:ok, members}
  end

  def get_state(room_id, user_id) do
    case call_if_alive(room_id, {:membership, user_id}) do
      %{"content" => %{"membership" => "join"}} ->
        {:ok, %{state: state}} = get(room_id)
        {:ok, state}

      %{"content" => %{"membership" => "leave"}} = membership ->
        event_id = Map.fetch!(membership, "event_id")
        {:ok, pdu} = PDU.get(event_id)
        {:ok, pdu.prev_state}

      _ ->
        {:error, :unauthorized}
    end
  end

  def get_state(room_id, user_id, type, state_key) do
    with {:ok, state} <- get_state(room_id, user_id),
         {:ok, event} <- Map.fetch(state, {type, state_key}) do
      {:ok, event}
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  @default_cutoff :timer.hours(24)
  def get_nearest_event(room_id, user_id, dir, timestamp, cutoff_ms \\ @default_cutoff) do
    order =
      case dir do
        :forward -> :ascending
        :backward -> :descending
      end

    latest_joined_at_depth = users_latest_join_depth(room_id, user_id)
    filter = %{limit: 1, contains_url: :none, types: :none, senders: :none}

    fn ->
      room_id
      |> PDU.nearest_event_cursor(user_id, filter, timestamp, cutoff_ms, latest_joined_at_depth, order)
      |> PDU.next_answers(1, :cleanup)
      |> Enum.to_list()
    end
    |> Memento.transaction()
    |> case do
      {:ok, []} ->
        :none

      {:ok, [event]} ->
        {:ok, event}

      {:error, error} ->
        Logger.error(
          "tried to fetch a nearby event for #{inspect(user_id)} at timestamp #{timestamp}, but got error: #{inspect(error)}"
        )

        {:error, :internal}
    end
  end

  @doc """
  Gets the %Room{} under the given room_id
  """
  def get(id), do: Memento.transaction(fn -> Memento.Query.read(__MODULE__, id) end)

  @doc """
  Gets all %Room{}s by a list of IDs
  """
  @spec all(Enumerable.t(room_id :: String.t())) :: {:ok, [t()]} | {:error, any()}
  def all(ids) do
    match_head = __MODULE__.__info__().query_base
    match_spec = for id <- ids, do: {put_elem(match_head, 1, id), [], [:"$_"]}

    Memento.transaction(fn -> Memento.Query.select_raw(__MODULE__, match_spec) end)
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
  def handle_call({:put_event, event}, _from, %Room{} = room) do
    # TOIMPL: handle duplicate annotations - M_DUPLICATE_ANNOTATION
    event_kind = if is_map_key(event, "state_key"), do: "state", else: "message"
    Utils.put_event_and_handle(room, event, "#{event_kind} (#{event["type"]})")
  end

  @impl GenServer
  def handle_call({:member?, user_id}, _from, %Room{} = room) do
    member? = get_in(room.state, [{"m.room.member", user_id}, "content", "membership"]) == "join"
    {:reply, member?, room}
  end

  @impl GenServer
  def handle_call({:membership, user_id}, _from, %Room{} = room) do
    membership = Map.get(room.state, {"m.room.member", user_id}, :not_found)
    {:reply, membership, room}
  end

  defp call_if_alive(room_id, message) do
    GenServer.call(via(room_id), message)
  catch
    :exit, {:noproc, _} ->
      case revive(room_id) do
        {:ok, ^room_id} -> GenServer.call(via(room_id), message)
        {:error, _} = error -> error
      end
  end

  defp via(room_id), do: {:via, Registry, {RadioBeam.RoomRegistry, room_id}}
end
