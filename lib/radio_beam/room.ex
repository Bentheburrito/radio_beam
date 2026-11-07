defmodule RadioBeam.Room do
  @moduledoc """
  API for interacting with rooms. Every room is represented by a Room.Server
  (a GenServer), which is responsible for correctly applying events to a room.
  All actions made against a room should be done through its GenServer using
  this API.
  """

  alias RadioBeam.Room
  alias RadioBeam.Room.Alias
  alias RadioBeam.Room.Database
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.Upgrades
  alias RadioBeam.Room.UserTimeline.Event
  alias RadioBeam.Room.Relations
  alias RadioBeam.User

  @attrs ~w|id chronicle redactions relationships|a
  @enforce_keys @attrs
  defstruct @attrs

  @type t() :: %__MODULE__{}
  @type id() :: String.t()
  @type event_id() :: String.t()

  ### API ###
  def generate_legacy_id(domain), do: "!#{legacy_id_localpart()}:#{domain}"
  defp legacy_id_localpart, do: 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

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

  @stripped_state_types Enum.map(~w|create name avatar topic join_rules canonical_alias encryption|, &"m.room.#{&1}")
  @stripped_state_event_fields ~w|content sender state_key type|a
  def get_invite_state_events(room_id, user_id) do
    @stripped_state_types
    |> Stream.map(&{&1, ""})
    |> Stream.concat([{"m.room.member", user_id}])
    |> Enum.flat_map(fn {type, state_key} ->
      case fetch_state_pdu_at(room_id, :current_state, type, state_key, true) do
        {:ok, %RadioBeam.Room.PDU{} = pdu} -> [Map.take(pdu.event, @stripped_state_event_fields)]
        {:error, :not_found} -> []
      end
    end)
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

  @doc "Tries to kick the given user from the given room"
  @spec kick(room_id :: String.t(), kicker_id :: String.t(), user_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def kick(room_id, kicker_id, user_id, reason \\ nil) do
    event = Events.membership(room_id, kicker_id, user_id, :leave, reason)

    Room.Server.send(room_id, event)
  end

  @doc "Tries to ban the given user from the given room"
  @spec ban(room_id :: String.t(), banner_id :: String.t(), user_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def ban(room_id, banner_id, user_id, reason \\ nil) do
    event = Events.membership(room_id, banner_id, user_id, :ban, reason)

    Room.Server.send(room_id, event)
  end

  @doc "Tries to unban the given user from the given room"
  @spec unban(room_id :: String.t(), unbanner_id :: String.t(), user_id :: String.t(), reason :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :unauthorized | :room_does_not_exist | :internal}
  def unban(room_id, unbanner_id, user_id, reason \\ nil) do
    event = Events.membership(room_id, unbanner_id, user_id, :leave, reason)

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

  @doc """
  Gets membership events in the given room. If an `at_event_id` is provided,
  returns memberships as of that event. Defaults to the current room state.
  The requesting user must have been a member of the room at the point in
  which these events are requested.
  """
  def get_members(room_id, user_id, at_event_id \\ :latest_visible, membership_filter \\ fn _ -> true end)

  def get_members(room_id, user_id, at_event_id_or_current, membership_filter) do
    with true <- User.RoomMemberships.has?(user_id, room_id),
         {:ok, room} <- get(room_id),
         {:ok, latest_visible_state_events} <- get_latest_visible_state(room, at_event_id_or_current, user_id) do
      {:ok, filter_member_events(latest_visible_state_events, membership_filter)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp get_latest_visible_state(room, :latest_visible, user_id) do
    with {:ok, membership_event_id} <- Room.Core.get_state_mapping(room, "m.room.member", user_id),
         {:ok, membership_event} <- expect_one_event(room.id, user_id, membership_event_id, false),
         {:ok, state_mapping} <- get_mapping_based_on_membership(room, membership_event) do
      state_event_id_stream = Stream.map(state_mapping, fn {_key, event_id} -> event_id end)
      {:ok, Room.UserTimeline.map_filter_user_events(room.id, user_id, state_event_id_stream, false)}
    end
  end

  defp get_latest_visible_state(room, "$" <> _ = at_event_id, user_id) do
    # the fact that user_id can see at_event implies they have perms to see
    # state at that event - no need to do add'l membership checks like in the
    # prev fxn clause.
    with {:ok, _at_event} <- expect_one_event(room.id, user_id, at_event_id, false) do
      state_event_id_stream =
        room |> Room.Core.get_state_mapping_at(at_event_id) |> Stream.map(fn {_key, event_id} -> event_id end)

      {:ok, Room.UserTimeline.map_filter_user_events(room.id, user_id, state_event_id_stream, false)}
    end
  end

  defp get_mapping_based_on_membership(room, %{content: %{"membership" => "join"}}),
    do: {:ok, Room.Core.get_state_mapping(room)}

  defp get_mapping_based_on_membership(room, %{content: %{"membership" => membership}, id: event_id})
       when membership in ~w|leave kick|, do: {:ok, Room.Core.get_state_mapping_at(room, event_id)}

  defp get_mapping_based_on_membership(_room, _event), do: {:error, :unauthorized}

  defp filter_member_events(state_events, membership_filter) do
    Stream.filter(state_events, fn
      %{type: "m.room.member"} = event -> membership_filter.(get_in(event.content["membership"]))
      _ -> false
    end)
  end

  @doc """
  Gets state events in the given room. The requesting user must have been a
  member of the room at some point.
  """
  def get_state(room_id, user_id) do
    with {:ok, room} <- get(room_id),
         {:ok, use_state_at} <- use_state_at(room, user_id) do
      state_mapping =
        case use_state_at do
          :latest_event -> Room.Core.get_state_mapping(room)
          event_id -> Room.Core.get_state_mapping_at(room, event_id)
        end

      state_event_ids = Stream.map(state_mapping, fn {_key, event_id} -> event_id end)

      {:ok, Room.UserTimeline.map_filter_user_events(room_id, user_id, state_event_ids)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def get_state(room_id, user_id, type, state_key) do
    with {:ok, room} <- get(room_id),
         {:ok, state_event_id} <- get_state_event_id_based_on_membership(room, user_id, type, state_key) do
      expect_one_event(room_id, user_id, state_event_id, false)
    end
  end

  defp get_state_event_id_based_on_membership(room, user_id, type, state_key) do
    case use_state_at(room, user_id) do
      {:ok, :latest_event} -> Room.Core.get_state_mapping(room, type, state_key)
      {:ok, event_id} -> Room.Core.get_state_mapping_at(room, event_id, type, state_key)
      {:error, _} = error -> error
    end
  end

  defp use_state_at(room, user_id) do
    with {:ok, membership_event_id} <- Room.Core.get_state_mapping(room, "m.room.member", user_id),
         {:ok, membership_event} <- expect_one_event(room.id, user_id, membership_event_id, false) do
      case membership_event.content do
        %{"membership" => "join"} -> {:ok, :latest_event}
        %{"membership" => membership} when membership in ~w|leave kick| -> {:ok, membership_event.id}
        _else -> {:error, :unauthorized}
      end
    else
      _else -> {:error, :unauthorized}
    end
  end

  defp expect_one_event(room_id, user_id, event_id, bundle_aggregations?) do
    case Room.UserTimeline.map_filter_user_events(room_id, user_id, [event_id], bundle_aggregations?) do
      [event] -> {:ok, event}
      _ -> {:error, :unauthorized}
    end
  end

  def fetch_state_pdu_at(room_id, at_event_id, type, state_key, apply_at_event? \\ false) do
    with {:ok, %__MODULE__{} = room} <- get(room_id),
         {:ok, event_id} <- Room.Core.get_state_mapping_at(room, at_event_id, type, state_key, apply_at_event?),
         %RadioBeam.Room.PDU{} = pdu <- Room.Core.fetch_pdu!(room, event_id) do
      {:ok, pdu}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def fetch_pdu(room_id, event_id) do
    with {:ok, %__MODULE__{} = room} <- get(room_id),
         %RadioBeam.Room.PDU{} = pdu <- Room.Core.fetch_pdu!(room, event_id) do
      {:ok, pdu}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def all_joined_members(room_id, event_id) do
    with {:ok, %__MODULE__{} = room} <- get(room_id) do
      %{} = mapping = Room.Core.get_state_mapping_at(room, event_id, true)

      for {{"m.room.member", _}, event_id} <- mapping,
          pdu <- [Room.Core.fetch_pdu!(room, event_id)],
          pdu.event.content["membership"] == "join",
          do: pdu.event.state_key
    end
  end

  def get_nearest_event(room_id, user_id, dir, timestamp) when dir in ~w|forward backward|a do
    with {:ok, event} <- Room.UserTimeline.nearest_user_event_to_timestamp(room_id, user_id, timestamp, dir) do
      {:ok, event.id, event.origin_server_ts}
    end
  end

  def upgrade(room_id, user_id, new_version, addl_creator_ids) do
    with {:ok, room} <- get(room_id) do
      deps = %{get_state: &get_state/4, put_state: &put_state/5, create_room: &create/2}
      Upgrades.perform(room, user_id, new_version, addl_creator_ids, deps)
    end
  end

  def get_thread_event_ids(room_id, user_id, include, limit, from \\ :latest) do
    with {:ok, from} <- map_from_event_id_to_stream_number(room_id, from) do
      case Room.Threads.get_thread_event_ids(room_id, user_id, include, limit, from) do
        [] -> {:ok, [], :end}
        thread_event_maps -> {:ok, thread_event_maps, List.last(thread_event_maps).event_id}
      end
    end
  end

  defp map_from_event_id_to_stream_number(_room_id, :latest), do: {:ok, :latest}

  defp map_from_event_id_to_stream_number(room_id, "$" <> _ = from_event_id) do
    with {:ok, %{stream_number: stream_number}} <- fetch_pdu(room_id, from_event_id) do
      {:ok, stream_number}
    end
  end

  def get_children(room_id, user_id, event_id, limit, opts) do
    Relations.get_children(room_id, user_id, event_id, limit, Keyword.put(opts, :get_event, &get_event/4))
  end

  def get_hierarchy(room_id, user_id, already_seen \\ MapSet.new()) do
    with {:ok, state_events} <- get_state(room_id, user_id) do
      descriptions =
        state_events
        |> Stream.filter(&(&1.type == "m.space.child" and &1.state_key not in already_seen))
        # sort per level of depth - spec doesn't define an order here, but it
        # helps test the DFS constraint, since `get_state/2` returns events in
        # no particular order
        |> Enum.sort({:asc, Event})
        |> Enum.flat_map(fn m_child_space_event ->
          child_room_id = m_child_space_event.state_key

          with :ok <- validate_space_child_visible(child_room_id, user_id),
               {:ok, descriptions} <- get_hierarchy(child_room_id, user_id, MapSet.put(already_seen, child_room_id)) do
            [hierarchy_description(child_room_id) | descriptions]
          else
            {:error, error} when error in ~w|not_found not_visible|a -> []
          end
        end)

      {:ok, descriptions}
    end
  end

  defp validate_space_child_visible(child_room_id, user_id) do
    case User.RoomMemberships.fetch(user_id, child_room_id) do
      # TODO: join_rules == public, history_visibility == world_readable,
      # restricted, and knock checks may make room visible too
      {:ok, membership} when membership in ~w|join invite| -> :ok
      _else -> {:error, :not_visible}
    end
  end

  defp hierarchy_description(child_room_id) do
    %{
      # why would we include this when these links will have an entry right
      # after this one???? Isn't that the point of doing a DFS?????
      children_state: [],
      # radio_beam does not support the legacy guests feature
      guest_can_join: false,
      # TODO
      num_joined_members: 0,
      room_id: child_room_id,
      # TODO
      world_readable: false
    }
  end

  defp get(id) do
    with {:error, :not_found} <- Database.fetch_room(id), do: {:error, :unauthorized}
  end
end
