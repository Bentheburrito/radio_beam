defmodule RadioBeam.Room do
  @moduledoc """
  API for interacting with rooms. Every room is represented by a GenServer, 
  which is responsible for correctly applying events to a room. All actions 
  made against a room should be done through its GenServer by using this 
  module.
  """

  @types [
    id: :string,
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

  alias RadioBeam.Room.Timeline
  alias RadioBeam.Repo
  alias RadioBeam.Repo.Transaction
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias Phoenix.PubSub
  alias Polyjuice.Util.Identifiers.V1.RoomIdentifier
  alias RadioBeam.PDU
  alias RadioBeam.PubSub, as: PS
  alias RadioBeam.Room
  alias RadioBeam.Room.Core
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.RoomSupervisor
  alias RadioBeam.User

  @type t() :: %__MODULE__{}
  @type id() :: String.t()

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

    create_event = Events.create(room_id, creator.id, room_version, Keyword.get(opts, :content, %{}))
    creator_join_event = Events.membership(room_id, creator.id, creator.id, :join)
    power_levels_event = Events.power_levels(room_id, creator.id, Keyword.get(opts, :power_levels, %{}))

    wrapped_canonical_alias_event =
      case Keyword.get(opts, :alias) do
        nil -> []
        alias_localpart -> [Events.canonical_alias(room_id, creator.id, alias_localpart, server_name)]
      end

    visibility = Keyword.get(opts, :visibility, :private)

    unless visibility in [:public, :private] do
      raise "option :visibility must be one of [:public, :private]"
    end

    preset = Keyword.get(opts, :preset, (visibility == :private && :private_chat) || :public_chat)

    unless preset in [:public_chat, :private_chat, :trusted_private_chat] do
      raise "option :preset must be one of [:public_chat, :private_chat, :trusted_private_chat]"
    end

    preset_events = Events.from_preset(preset, room_id, creator.id)

    wrapped_name_event =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [Events.name(room_id, creator.id, name)]
      end

    wrapped_topic_event =
      case Keyword.get(opts, :topic) do
        nil -> []
        topic -> [Events.topic(room_id, creator.id, topic)]
      end

    invite_events =
      opts
      |> Keyword.get(:invite, [])
      |> Enum.map(&Events.membership(room_id, creator.id, &1, :invite))

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

  def start_link({room_id, _events_or_room} = init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: via(room_id))
  end

  @state :"$3"
  @doc "Returns all room IDs that `user_id` is joined to"
  @spec joined(user_id :: String.t()) :: [room_id :: String.t()]
  def joined(user_id) do
    match_head = __MODULE__.__info__().query_base

    joined_guard =
      {:==, "join", {:map_get, "membership", {:map_get, "content", {:map_get, {{"m.room.member", user_id}}, @state}}}}

    match_spec = [{match_head, [joined_guard], [:"$1"]}]

    Repo.one_shot(fn -> Memento.Query.select_raw(__MODULE__, match_spec, coerce: false) end)
  end

  @doc """
  Returns all rooms whose state has a `{m.room.member, user_id}` key
  """
  @spec all_where_has_membership(user_id :: String.t()) :: [room_id :: String.t()]
  def all_where_has_membership(user_id) do
    match_head = __MODULE__.__info__().query_base
    has_membership_guard = {:is_map_key, {{"m.room.member", user_id}}, @state}
    match_spec = [{match_head, [has_membership_guard], [:"$1"]}]

    Repo.one_shot(fn -> Memento.Query.select_raw(__MODULE__, match_spec, coerce: false) end)
  end

  @doc "Tries to invite the invitee to the given room, if the inviter has perms"
  @spec invite(room_id :: String.t(), inviter_id :: String.t(), invitee_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def invite(room_id, inviter_id, invitee_id, reason \\ nil) do
    event = Events.membership(room_id, inviter_id, invitee_id, :invite, reason)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc "Tries to join the given user to the given room"
  @spec join(room_id :: String.t(), joiner_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def join(room_id, joiner_id, reason \\ nil) do
    event = Events.membership(room_id, joiner_id, joiner_id, :join, reason)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc "Tries to remove the given user from the given room"
  @spec leave(room_id :: String.t(), user_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def leave(room_id, user_id, reason \\ nil) do
    event = Events.membership(room_id, user_id, user_id, :leave, reason)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc "Helper function to set the name of the room"
  @spec set_name(room_id :: String.t(), user_id :: String.t(), name :: String.t()) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def set_name(room_id, user_id, name) do
    event = Events.name(room_id, user_id, name)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc """
  Sets the room state for the given type and state key.
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
    event = Events.state(room_id, type, user_id, content, state_key)

    call_if_alive(room_id, {:put_event, event})
  end

  @doc "Sends a Message Event to the room"
  @spec send(room_id :: String.t(), user_id :: String.t(), type :: String.t(), content :: map()) ::
          {:ok, event_id :: String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def send(room_id, user_id, type, content) do
    event = Events.message(room_id, user_id, type, content)

    call_if_alive(room_id, {:put_event, event})
  end

  def get_event(_room_id, user_id, event_id) do
    with {:ok, pdu} <- PDU.get(event_id),
         [^pdu] <- Timeline.filter_authz([pdu], :forward, user_id) do
      {:ok, pdu}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def member?(room_id, user_id), do: call_if_alive(room_id, {:member?, user_id})

  def get_membership(room_id, user_id), do: call_if_alive(room_id, {:membership, user_id})

  def get_members(room_id, user_id, at_event_id \\ :current, membership_filter \\ fn _ -> true end)

  def get_members(room_id, user_id, :current, membership_filter) do
    case get_state(room_id, user_id) do
      {:ok, state} -> state |> Stream.map(&elem(&1, 1)) |> get_members_from_state(membership_filter)
      error -> error
    end
  end

  def get_members(room_id, user_id, "$" <> _ = at_event_id, membership_filter) do
    with {:ok, pdu} <- PDU.get(at_event_id),
         [^pdu] <- Timeline.filter_authz([pdu], :forward, user_id),
         {:ok, state_events} <- PDU.all(pdu.state_events) do
      {:ok, %{version: version}} = get(room_id)

      state_events
      |> Stream.map(&PDU.to_event(&1, version, :strings))
      |> get_members_from_state(membership_filter)
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp get_members_from_state(state, membership_filter) do
    members =
      Enum.filter(state, fn
        %{"type" => "m.room.member"} = event -> event |> get_in(["content", "membership"]) |> membership_filter.()
        _ -> false
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

        case PDU.all(pdu.state_events) do
          {:ok, state_events} ->
            {:ok, %{version: version}} = get(room_id)
            {:ok, Map.new(state_events, &{{&1.type, &1.state_key}, PDU.to_event(&1, version, :strings)})}

          _ ->
            {:error, :unauthorized}
        end

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
    Repo.one_shot(fn ->
      room_id
      |> EventGraph.get_nearest_event(dir, timestamp, cutoff_ms)
      |> get_nearest_event(user_id)
    end)
  end

  defp get_nearest_event({:ok, pdu}, user_id) do
    if Timeline.authz_to_view?(pdu, user_id), do: {:ok, pdu}, else: {:error, :not_found}
  end

  defp get_nearest_event({:ok, pdu, cont}, user_id) do
    if Timeline.authz_to_view?(pdu, user_id),
      do: {:ok, pdu},
      else: get_nearest_event(EventGraph.get_nearest_event(cont), user_id)
  end

  defp get_nearest_event({:error, :not_found}, _user_id), do: :none

  @doc """
  Gets the %Room{} under the given room_id
  """
  def get(id) do
    Repo.one_shot(fn ->
      case Memento.Query.read(__MODULE__, id) do
        nil -> {:error, :not_found}
        room -> {:ok, room}
      end
    end)
  end

  @stripped_state_types Enum.map(~w|create name avatar topic join_rules canonical_alias encryption|, &"m.room.#{&1}")
  def stripped_state_types, do: @stripped_state_types

  @stripped_state_keys Enum.map(@stripped_state_types, &{&1, ""})
  @stripped_keys ["content", "sender", "state_key", "type"]
  @doc "Returns the stripped state of the given room."
  def stripped_state(room) do
    room.state |> Map.take(@stripped_state_keys) |> Enum.map(fn {_, event} -> Map.take(event, @stripped_keys) end)
  end

  ### IMPL ###

  @impl GenServer
  def init({room_id, events_or_room}) do
    case events_or_room do
      [%{"type" => "m.room.create", "content" => %{"room_version" => version}} | _] = events ->
        init_room = %Room{id: room_id, latest_event_ids: [], state: %{}, version: version}

        case put_events(init_room, events) do
          {:ok, %Room{} = room, _pdus} -> {:ok, room}
          {:error, :unauthorized} -> {:stop, :invalid_state}
          {:error, %Ecto.Changeset{} = changeset} -> {:stop, inspect(changeset.errors)}
          {:error, :alias_in_use} -> {:stop, :alias_in_use}
          {:error, _txn_fxn_name, error} -> {:stop, error}
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

    case put_event(room, event) do
      {:ok, room, [pdu]} ->
        PubSub.broadcast(PS, PS.all_room_events(room.id), {:room_event, room.id, pdu})

        if pdu.type in @stripped_state_types,
          do: PubSub.broadcast(PS, PS.stripped_state_events(room.id), {:room_stripped_state, room.id, pdu})

        if pdu.type == "m.room.member" do
          if pdu.content["membership"] == "invite" do
            PubSub.broadcast(PS, PS.invite_events(pdu.state_key), {:room_invite, room, pdu})
          end

          LazyLoadMembersCache.mark_dirty(room.id, pdu.state_key)
        end

        {:reply, {:ok, pdu.event_id}, room}

      {:error, :unauthorized} = e ->
        Logger.info("rejecting a(n) #{event_kind} event for being unauthorized: #{inspect(event)}")
        {:reply, e, room}

      {:error, error} ->
        Logger.error("an error occurred trying to put a(n) #{event_kind} event: #{inspect(error)}")
        {:reply, {:error, :internal}, room}
    end
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

  defp put_event(%Room{} = room, event), do: put_events(room, [event])

  defp put_events(%Room{} = room, events) do
    latest_pdus =
      case PDU.all(room.latest_event_ids) do
        {:ok, pdus} -> pdus
        {:error, _} -> []
      end

    put_result =
      Enum.reduce_while(events, {room, [], latest_pdus}, fn event, {%Room{} = room, pdus, parents} ->
        with {:ok, event} <- Core.authorize(room, event),
             {:ok, pdu} <- EventGraph.append(room, parents, event) do
          room = room |> Core.update_state(PDU.to_event(pdu, room.version, :strings)) |> Core.put_tip([pdu.event_id])
          {:cont, {room, [pdu | pdus], [pdu]}}
        else
          error -> {:halt, error}
        end
      end)

    with {%Room{} = room, [%PDU{} | _] = pdus, _parents} <- put_result,
         {:ok, _} <- persist(room, pdus) do
      {:ok, room, pdus}
    end
  end

  defp persist(room, pdus) do
    init_txn = Transaction.add_fxn(Transaction.new(), :room, fn -> {:ok, Memento.Query.write(room)} end)

    pdus
    |> Enum.reduce(init_txn, &persist_pdu_with_side_effects/2)
    |> Transaction.execute()
  end

  defp persist_pdu_with_side_effects(%PDU{type: "m.room.canonical_alias"} = pdu, txn) do
    [pdu.content["alias"] | Map.get(pdu.content, "alt_aliases", [])]
    |> Stream.reject(&is_nil/1)
    |> Enum.reduce(txn, &Transaction.add_fxn(&2, "put_alias_#{&1}", fn -> Room.Alias.put(&1, pdu.room_id) end))
    |> Transaction.add_fxn(:pdu, fn -> EventGraph.persist_pdu(pdu) end)
  end

  # TOIMPL: add room to published room list if visibility option was set to :public
  defp persist_pdu_with_side_effects(%PDU{} = pdu, txn),
    do: Transaction.add_fxn(txn, :pdu, fn -> EventGraph.persist_pdu(pdu) end)

  defp call_if_alive(room_id, message) do
    GenServer.call(via(room_id), message)
  catch
    :exit, {:noproc, _} ->
      case revive(room_id) do
        {:ok, ^room_id} -> GenServer.call(via(room_id), message)
        {:error, _} = error -> error
      end
  end

  defp revive(room_id) do
    case get(room_id) do
      {:ok, %Room{} = room} ->
        case DynamicSupervisor.start_child(RoomSupervisor, {__MODULE__, {room.id, room}}) do
          {:ok, _pid} -> {:ok, room_id}
          error -> error
        end

      {:error, :not_found} ->
        {:error, :room_does_not_exist}

      {:error, error} ->
        Logger.error("Error reviving #{room_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp via(room_id), do: {:via, Registry, {RadioBeam.RoomRegistry, room_id}}
end
