defmodule RadioBeam.Room do
  @moduledoc """
  API for interacting with rooms. Every room is represented by a Room.Server
  (a GenServer), which is responsible for correctly applying events to a room.
  All actions made against a room should be done through its GenServer using
  this API.
  """

  require Logger

  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.Room
  alias RadioBeam.Room.Alias
  alias RadioBeam.Room.Database
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.Events
  alias RadioBeam.User

  @attrs ~w|id dag state redactions relationships|a
  @enforce_keys @attrs
  defstruct @attrs

  @type t() :: %__MODULE__{}
  @type id() :: String.t()
  @type event_id() :: String.t()

  ### API ###

  def generate_id(domain \\ RadioBeam.Config.server_name()),
    do: Polyjuice.Util.Identifiers.V1.RoomIdentifier.generate(domain)

  @doc """
  Create a new room with the given options. Returns `{:ok, room_id}` if the 
  room was successfully started.
  """
  @spec create(User.id() | User.t(), [Room.Core.create_opt() | {:version, String.t()}]) :: {:ok, id()} | {:error, any()}
  def create(creator_id, opts \\ []) do
    room_version = Keyword.get(opts, :version, RadioBeam.Config.default_room_version())

    if User.exists?(creator_id) do
      Room.Server.create(room_version, creator_id, opts)
    else
      {:error, :unknown_user}
    end
  end

  def exists?(room_id) do
    case get(room_id) do
      {:ok, %Room{}} -> true
      {:error, _} -> false
    end
  end

  @doc "Returns all room IDs that `user_id` is joined to"
  @spec joined(user_id :: String.t()) :: MapSet.t(id())
  def joined(user_id) do
    case Room.View.all_participating(user_id) do
      {:ok, %{latest_known_join_pdus: join_pdus_map}} -> Stream.map(join_pdus_map, fn {room_id, _pdu} -> room_id end)
      {:error, :not_found} -> []
    end
  end

  @doc """
  Returns all rooms whose state has a `{"m.room.member", user_id}` key
  """
  @spec all_where_has_membership(user_id :: String.t()) :: MapSet.t(id())
  def all_where_has_membership(user_id) do
    case Room.View.all_participating(user_id) do
      {:ok, %{all: all}} -> all
      _ -> MapSet.new()
    end
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

  @spec send_text_message(room_id :: String.t(), sender_id :: String.t(), message :: String.t()) ::
          {:ok, event_id :: String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def send_text_message(room_id, sender_id, message) do
    Room.Server.send(room_id, Events.text_message(room_id, sender_id, message))
  end

  def get_event(room_id, user_id, event_id, bundle_aggregates? \\ true) do
    expect_one_event(room_id, user_id, event_id, bundle_aggregates?)
  end

  def redact_event(room_id, user_id, event_id, reason) do
    Room.Server.send(room_id, Events.redaction(room_id, user_id, event_id, reason))
  end

  def lookup_id_by_alias(%Alias{} = alias), do: Database.fetch_room_id_by_alias(alias)

  def bind_alias_to_room(%Alias{} = alias, room_id, ensure_room_exists? \\ true),
    do: Database.create_alias(alias, room_id, ensure_room_exists?)

  def get_members(room_id, user_id, at_event_id \\ :latest_visible, membership_filter \\ fn _ -> true end)

  def get_members(room_id, user_id, at_event_id_or_current, membership_filter) do
    with true <- room_id in all_where_has_membership(user_id),
         {:ok, room} <- get(room_id),
         {:ok, latest_visible_state_pdus} <- get_latest_visible_state(room, at_event_id_or_current, user_id),
         {:ok, member_event_ids} <- get_member_event_ids_at_pdu(latest_visible_state_pdus, membership_filter),
         {:ok, member_events} <- Room.View.get_events(room_id, user_id, member_event_ids) do
      {:ok, member_events}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp get_latest_visible_state(room, :latest_visible, user_id) do
    case Room.State.fetch(room.state, "m.room.member", user_id) do
      {:ok, %{event: %{content: %{"membership" => "join"}}}} ->
        {:ok, Room.State.get_all(room.state)}

      {:ok, %{event: %{content: %{"membership" => "leave"}, id: event_id}}} ->
        pdu = Room.DAG.fetch!(room.dag, event_id)
        {:ok, Room.State.get_all_at(room.state, pdu)}

      _else ->
        {:error, :unauthorized}
    end
  end

  defp get_latest_visible_state(room, "$" <> _ = at_event_id, _user_id) do
    pdu = Room.DAG.fetch!(room.dag, at_event_id)
    {:ok, Room.State.get_all_at(room.state, pdu)}
  end

  defp get_member_event_ids_at_pdu(state_pdus, membership_filter) do
    state_pdus
    |> Stream.map(fn {_key, pdu} -> pdu.event end)
    |> Stream.filter(fn
      %{type: "m.room.member"} = event -> membership_filter.(get_in(event.content["membership"]))
      _ -> false
    end)
    |> Stream.map(fn event -> event.id end)
    |> then(&{:ok, &1})
  end

  def get_state(room_id, user_id) do
    with {:ok, room} <- get(room_id),
         {:ok, use_state_at} <- use_state_at(room.state, user_id) do
      state =
        case use_state_at do
          :latest_event -> Room.State.get_all(room.state)
          %PDU{} = pdu -> Room.State.get_all_at(room.state, pdu)
        end

      state_event_ids = Stream.map(state, fn {_key, pdu} -> pdu.event.id end)

      Room.View.get_events(room_id, user_id, state_event_ids)
    else
      _ -> {:error, :unauthorized}
    end
  end

  def get_state(room_id, user_id, type, state_key) do
    with {:ok, room} <- get(room_id),
         {:ok, %PDU{} = state_pdu} <- get_state_at(room.state, user_id, type, state_key) do
      expect_one_event(room_id, user_id, state_pdu.event.id, false)
    end
  end

  defp get_state_at(room_state, user_id, type, state_key) do
    case use_state_at(room_state, user_id) do
      {:ok, :latest_event} -> Room.State.fetch(room_state, type, state_key)
      {:ok, %PDU{} = pdu} -> Room.State.fetch_at(room_state, type, state_key, pdu)
      {:error, _} = error -> error
    end
  end

  defp use_state_at(room_state, user_id) do
    case Room.State.fetch(room_state, "m.room.member", user_id) do
      {:ok, %{event: %{content: %{"membership" => "join"}}}} -> {:ok, :latest_event}
      {:ok, %{event: %{content: %{"membership" => membership}}} = pdu} when membership in ~w|leave kick| -> {:ok, pdu}
      {:ok, _} -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  defp expect_one_event(room_id, user_id, event_id, bundle_aggregations?) do
    with {:ok, event_stream} <- Room.View.get_events(room_id, user_id, [event_id], bundle_aggregations?),
         [event] <- Enum.take(event_stream, 1) do
      {:ok, event}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def get_nearest_event(room_id, user_id, dir, timestamp) when dir in ~w|forward backward|a do
    with {:ok, event_stream} <- Room.View.nearest_events_stream(room_id, user_id, timestamp, dir) do
      case Enum.take(event_stream, 1) do
        [] -> {:error, :not_found}
        [{"$" <> _ = event_id, origin_server_ts}] -> {:ok, event_id, origin_server_ts}
      end
    end
  end

  def get_children(room_id, user_id, event_id, limit, opts) do
    with {:ok, child_event_stream} <- Room.View.get_child_events(room_id, user_id, event_id) do
      rel_type = Keyword.get(opts, :rel_type)
      event_type = Keyword.get(opts, :event_type)

      comparator = &(TopologicalID.compare(&1, &2.order_id) in [:gt, :eq])
      before_start? = maybe_event_comparator(room_id, user_id, Keyword.fetch(opts, :to), comparator, fn _ -> false end)

      comparator = &(TopologicalID.compare(&2.order_id, &1) == :lt)
      before_end? = maybe_event_comparator(room_id, user_id, Keyword.fetch(opts, :from), comparator, fn _ -> true end)

      # note: we take(limit) *after* sorting, since child_event_stream does
      # not traverse child events in topological order (as of writing,
      # RelatedEvents maps child event IDs in a MapSet (which is unordered).
      #
      # same reasoning for using the filter/reject instead of drop_/take_while
      child_events =
        child_event_stream
        # |> Stream.drop_while(before_start?)
        # |> Stream.take_while(before_end?)
        |> Stream.reject(before_start?)
        |> Stream.filter(before_end?)
        |> Stream.filter(&(filter_rel_type(&1, rel_type) and filter_event_type(&1, event_type)))
        |> apply_order(Keyword.get(opts, :order, :reverse_chronological))
        |> Enum.take(limit)

      # TOIMPL: support for `recurse?` option
      {:ok, child_events, _recurse_depth = 1}
    end
  end

  defp maybe_event_comparator(room_id, user_id, {:ok, event_id}, comparator, default) do
    case get_event(room_id, user_id, event_id, false) do
      {:ok, event} ->
        &comparator.(event.order_id, &1)

      {:error, :unauthorized} ->
        default
    end
  end

  defp maybe_event_comparator(_room_id, _user_id, :error, _comparator, default), do: default

  defp filter_rel_type(_pdu, nil), do: true
  defp filter_rel_type(%{content: %{"m.relates_to" => %{"rel_type" => rel_type}}}, rel_type), do: true
  defp filter_rel_type(_pdu, _rel_type), do: false

  defp filter_event_type(_pdu, nil), do: true
  defp filter_event_type(%{type: event_type}, event_type), do: true
  defp filter_event_type(_pdu, _event_type), do: false

  defp apply_order(event_stream, :chronological), do: Enum.sort_by(event_stream, & &1.order_id, {:asc, TopologicalID})

  defp apply_order(event_stream, :reverse_chronological),
    do: Enum.sort_by(event_stream, & &1.order_id, {:desc, TopologicalID})

  defp get(id) do
    with {:error, :not_found} <- Database.fetch_room(id), do: {:error, :unauthorized}
  end
end
