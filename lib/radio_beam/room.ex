defmodule RadioBeam.Room do
  @moduledoc """
  API for interacting with rooms. Every room is represented by a Room.Server
  (a GenServer), which is responsible for correctly applying events to a room.
  All actions made against a room should be done through its GenServer using
  this API.
  """

  require Logger

  alias RadioBeam.Room.Timeline
  alias RadioBeam.Repo
  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.User

  @attrs ~w|id dag state redactions relationships|a
  @enforce_keys @attrs
  defstruct @attrs

  @type t() :: %__MODULE__{}
  @type id() :: String.t()
  @type event_id() :: String.t()

  ### API ###

  @doc """
  Create a new room with the given options. Returns `{:ok, room_id}` if the 
  room was successfully started.
  """
  @spec create(User.t(), [Room.Core.create_opt()]) :: {:ok, id()} | {:error, any()}
  def create(room_version, %User{} = creator, opts \\ []), do: Room.Server.create(room_version, creator.id, opts)

  # read models per user:
  # - all rooms they have a m.room.member event in
  #   - all joined rooms
  # read models per user per room:
  # - latest visible state (all or by type + state_key)
  #   - latest known join event
  # - visible member state events at a given visible event
  #     NOTE: this can take an `at` pagination token
  # - read visible event by ID (via timeline?)
  # - nearest visible event to a timestamp in a direction
  # - relationships - get all visible children for a given visible event (with
  #   a certain level of recursion 
  # - room timeline
  #   - topological ordering of event history, filtered by visible to user (/messages, initial /sync)
  #   - stream ordering of event history, filtered by visible to user (/sync)
  #     - state delta if there are tons of msgs since `since`
  # read models per user per device per room:
  # - unchanged member events previously sent to the device (lazy loading members)

  @doc "Returns all room IDs that `user_id` is joined to"
  @spec joined(user_id :: String.t()) :: MapSet.t(id())
  def joined(user_id) do
    with {:ok, %{joined: joined}} <- Room.View.all_participating(user_id), do: joined
  end

  @doc """
  Returns all rooms whose state has a `{"m.room.member", user_id}` key
  """
  @spec all_where_has_membership(user_id :: String.t()) :: MapSet.t(id())
  def all_where_has_membership(user_id) do
    with {:ok, %{all: all}} <- Room.View.all_participating(user_id), do: all
  end

  @doc "Tries to invite the invitee to the given room, if the inviter has perms"
  @spec invite(room_id :: String.t(), inviter_id :: String.t(), invitee_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def invite(room_id, inviter_id, invitee_id, reason \\ nil) do
    event = Events.membership(room_id, inviter_id, invitee_id, :invite, reason)

    Room.Server.send(room_id, event)
  end

  @doc "Tries to join the given user to the given room"
  @spec join(room_id :: String.t(), joiner_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def join(room_id, joiner_id, reason \\ nil) do
    event = Events.membership(room_id, joiner_id, joiner_id, :join, reason)

    Room.Server.send(room_id, event)
  end

  @doc "Tries to remove the given user from the given room"
  @spec leave(room_id :: String.t(), user_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def leave(room_id, user_id, reason \\ nil) do
    event = Events.membership(room_id, user_id, user_id, :leave, reason)

    Room.Server.send(room_id, event)
  end

  @doc "Sets the name of the room"
  @spec set_name(room_id :: String.t(), user_id :: String.t(), name :: String.t()) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def set_name(room_id, user_id, name) do
    event = Events.name(room_id, user_id, name)

    Room.Server.send(room_id, event)
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
    Room.Server.send(room_id, Events.state(room_id, type, user_id, content, state_key))
  end

  @doc "Sends a Message Event to the room"
  @spec send(room_id :: String.t(), user_id :: String.t(), type :: String.t(), content :: map()) ::
          {:ok, event_id :: String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def send(room_id, user_id, type, content) do
    Room.Server.send(room_id, Events.message(room_id, user_id, type, content))
  end

  def get_event(room_id, user_id, event_id, bundle_aggregates? \\ true) do
    with {:ok, room} <- get(room_id),
         {:ok, pdu} <- Repo.fetch(PDU, event_id),
         true <- Timeline.pdu_visible_to_user?(pdu, user_id) do
      pdu = if bundle_aggregates?, do: Timeline.bundle_aggregations(room, pdu, user_id), else: pdu
      {:ok, pdu}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def redact_event(room_id, user_id, event_id, reason \\ nil) do
    Room.Server.send(room_id, Events.redaction(room_id, user_id, event_id, reason))
  end

  def member?(room_id, user_id) do
    case get(room_id) do
      {:ok, %{state: %{{"m.room.member", ^user_id} => %{content: %{"membership" => "join"}}}}} -> true
      _else -> false
    end
  end

  def get_membership(room_id, user_id) do
    case get(room_id) do
      {:ok, %{state: %{{"m.room.member", ^user_id} => membership_event}}} -> membership_event
      _else -> :not_found
    end
  end

  @doc """
  Gets the latest `"m.room.member"` pdu for the given user_id whose membership
  is `"join"`. If the user has never joined the room, `{:error, :never_joined}`
  is returned.
  """
  @spec get_latest_known_join(id() | t(), User.id()) :: {:ok, PDU.t()} | {:error, :never_joined}
  def get_latest_known_join("!" <> _ = room_id, user_id) do
    with {:ok, %Room{} = room} <- get(room_id), do: get_latest_known_join(room, user_id)
  end

  def get_latest_known_join(%Room{} = room, user_id) do
    with :error <- Map.fetch(room.latest_known_joins, user_id) do
      {:error, :never_joined}
    end
  end

  def get_members(room_id, user_id, at_event_id \\ :current, membership_filter \\ fn _ -> true end)

  def get_members(room_id, user_id, :current, membership_filter) do
    case get_state(room_id, user_id) do
      {:ok, state} -> state |> Stream.map(&elem(&1, 1)) |> get_members_from_state(membership_filter)
      error -> error
    end
  end

  def get_members(room_id, user_id, "$" <> _ = at_event_id, membership_filter) do
    with {:ok, %{room_id: ^room_id} = pdu} <- Repo.fetch(PDU, at_event_id),
         true <- Timeline.pdu_visible_to_user?(pdu, user_id),
         {:ok, state_events} <- Repo.get_all(PDU, pdu.state_events) do
      get_members_from_state(state_events, membership_filter)
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp get_members_from_state(state, membership_filter) do
    members =
      Enum.filter(state, fn
        %{type: "m.room.member"} = event -> membership_filter.(get_in(event.content["membership"]))
        _ -> false
      end)

    {:ok, members}
  end

  def get_state(room_id, user_id) do
    case get(room_id) do
      {:ok, %{state: %{{"m.room.member", ^user_id} => %{content: %{"membership" => "join"}}} = state}} ->
        {:ok, state}

      {:ok, %{state: %{{"m.room.member", ^user_id} => %{content: %{"membership" => "leave"}} = membership}}} ->
        {:ok, pdu} = Repo.fetch(PDU, membership.event_id)

        case Repo.get_all(PDU, pdu.state_events) do
          {:ok, state_events} ->
            {:ok, Map.new(state_events, &{{&1.type, &1.state_key}, &1})}

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
    Repo.transaction(fn ->
      room_id
      |> EventGraph.get_nearest_event(dir, timestamp, cutoff_ms)
      |> get_nearest_event(user_id)
    end)
  end

  defp get_nearest_event({:ok, pdu}, user_id) do
    if Timeline.pdu_visible_to_user?(pdu, user_id), do: {:ok, pdu}, else: {:error, :not_found}
  end

  defp get_nearest_event({:ok, pdu, cont}, user_id) do
    if Timeline.pdu_visible_to_user?(pdu, user_id),
      do: {:ok, pdu},
      else: get_nearest_event(EventGraph.get_nearest_event(cont), user_id)
  end

  defp get_nearest_event({:error, :not_found}, _user_id), do: :none

  defp get(id), do: Repo.fetch(Repo.Tables.Room, id)

  def generate_id(domain \\ RadioBeam.server_name()), do: Polyjuice.Util.Identifiers.V1.RoomIdentifier.generate(domain)
end
