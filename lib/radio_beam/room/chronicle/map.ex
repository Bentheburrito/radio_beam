defmodule RadioBeam.Room.Chronicle.Map do
  @moduledoc """
  A Room event chronicle implementation as an in-memory map.
  """
  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.DAG
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.PDU

  defstruct ~w|dag resolved_state_before_event|a

  @opaque t() :: %__MODULE__{
            dag: DAG.t(),
            resolved_state_before_event: %{Room.event_id() => %{{String.t(), String.t()} => Room.event_id()}}
          }

  def new!(%{"content" => %{"room_version" => version}} = create_event_attrs, dag_backend) do
    create_event_attrs = Map.put(create_event_attrs, "prev_events", [])

    with {:ok, %AuthorizedEvent{} = create_event} <- authorize_event(%{}, version, create_event_attrs) do
      dag = dag_backend.new!(create_event.id, create_event)

      %__MODULE__{dag: dag, resolved_state_before_event: %{create_event.id => %{}}}
    end
  end

  def room_id(%__MODULE__{} = chronicle) do
    case DAG.root!(chronicle.dag).payload do
      %{content: %{"room_version" => "12"}, id: "$" <> event_id_b64} -> "!" <> event_id_b64
      %{room_id: room_id} -> room_id
    end
  end

  def room_version(%__MODULE__{} = chronicle), do: Map.fetch!(DAG.root!(chronicle.dag).payload.content, "room_version")

  def get_create_event(%__MODULE__{} = chronicle), do: DAG.root!(chronicle.dag).payload

  @doc """
  Validates the given event attrs map and, if valid, appends it to the DAG.
  """
  def try_append(%__MODULE__{} = chronicle, event_attrs) do
    prev_event_ids = DAG.zid_keys(chronicle.dag)
    event_attrs = Map.put(event_attrs, "prev_events", prev_event_ids)
    state_mapping_before_event = resolve_state(chronicle, prev_event_ids, true)

    # TODO: Polyjuice RoomState protocol
    state_mapping =
      Map.new(state_mapping_before_event, fn {state_event_type_and_key, event_id} ->
        %DAG.Vertex{payload: event} = DAG.fetch!(chronicle.dag, event_id)
        {state_event_type_and_key, event}
      end)

    with {:ok, %AuthorizedEvent{} = event} <- authorize_event(state_mapping, room_version(chronicle), event_attrs) do
      chronicle = put_in(chronicle.resolved_state_before_event[event.id], state_mapping_before_event)
      {:ok, update_in(chronicle.dag, &DAG.append!(&1, event.id, event)), event}
    end
  end

  @doc """
  Gets the state at the given event
  """
  def get_state_event_mapping_before(%__MODULE__{} = chronicle, event_id) do
    chronicle
    |> get_state_mapping(event_id)
    # TODO: Polyjuice RoomState protocol
    |> Map.new(fn {state_event_type_and_key, event_id} ->
      %DAG.Vertex{payload: event} = DAG.fetch!(chronicle.dag, event_id)
      {state_event_type_and_key, event}
    end)
  end

  @doc """
  Gets the state event ID mapping at the given event
  """
  def get_state_mapping(%__MODULE__{} = chronicle, event_id \\ :current_state, apply_event_ids? \\ false) do
    event_ids = if event_id == :current_state, do: DAG.zid_keys(chronicle.dag), else: [event_id]

    # TODO: resolution may fail if we are missing events (only relevant in a federated context)
    resolve_state(chronicle, event_ids, apply_event_ids?)
  end

  def fetch_event(%__MODULE__{} = chronicle, event_id) do
    with {:ok, %DAG.Vertex{} = vertex} <- DAG.fetch(chronicle.dag, event_id) do
      {:ok, vertex.payload}
    end
  end

  # for read model
  def fetch_pdu!(%__MODULE__{} = chronicle, event_id) do
    %DAG.Vertex{} = vertex = DAG.fetch!(chronicle.dag, event_id)
    PDU.new!(vertex.payload, vertex.parents, vertex.stream_id)
  end

  def replace!(%__MODULE__{} = chronicle, %AuthorizedEvent{} = event) do
    update_in(chronicle.dag, &DAG.replace!(&1, event.id, event))
  end

  # given a %Chronicle{} and its DAG's forward extremeties, returns the current
  # %{{type, state_key} => event_id} state mapping of the room. The state is
  # resolved from the forward extremeties of the chronicle's DAG.
  defp resolve_state(%__MODULE__{} = chronicle, [event_id], apply_event_ids?) do
    # easy* case, only one parent/state set to consider.
    # *at least, until it's possible for us to not have a parent event -
    # would need to backfill first.

    # TODO: if event ID not present, don't raise, recursively resolve
    state_mapping_before = Map.fetch!(chronicle.resolved_state_before_event, event_id)

    if apply_event_ids? do
      %DAG.Vertex{} = event_vertex = DAG.fetch!(chronicle.dag, event_id)
      state_mapping_after(event_vertex, state_mapping_before)
    else
      state_mapping_before
    end
  end

  # hard case, resolve state of parents, use algorithm based on room
  # version.
  defp resolve_state(%__MODULE__{} = _chronicle, [_, _ | _], _apply_event_ids?),
    do: raise("STATE RESOLUTION NOT IMPLEMENTED YET")

  # If E is a message event, then S′(E) = S(E).
  defp state_mapping_after(%DAG.Vertex{payload: %AuthorizedEvent{state_key: :none}}, state_mapping_before),
    do: state_mapping_before

  # If E is a state event, then S′(E) is S(E), except that its entry
  # corresponding to the event_type and state_key of E is replaced by the
  # event_id of E.
  defp state_mapping_after(
         %DAG.Vertex{payload: %AuthorizedEvent{type: type, state_key: state_key, id: event_id}},
         state_mapping_before
       )
       when is_binary(state_key) do
    Map.put(state_mapping_before, {type, state_key}, event_id)
  end

  defp authorize_event(state_mapping, room_version, %{} = event_attrs) do
    auth_events = select_auth_events(state_mapping, room_version, event_attrs)

    if authorized?(state_mapping, room_version, event_attrs, auth_events) do
      authz_event_attrs = Map.put(event_attrs, "auth_events", Enum.map(auth_events, & &1.id))

      with {:ok, populated_event_attrs} <- compute_and_put_hashes(authz_event_attrs, room_version) do
        prev_state_content =
          if state_key = Map.get(event_attrs, "state_key") do
            case Map.fetch(state_mapping, {event_attrs["type"], state_key}) do
              {:ok, %{content: prev_state_content}} -> prev_state_content
              :error -> :none
            end
          else
            :none
          end

        authz_event =
          populated_event_attrs
          |> Map.put("prev_state_content", prev_state_content)
          # if there is no room_id, make it the event's hash (replacing the $ sigil with !)
          |> Map.put_new_lazy("room_id", fn -> "!#{binary_slice(populated_event_attrs["id"], 1..-1//1)}" end)
          |> AuthorizedEvent.new!()

        {:ok, authz_event}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp compute_and_put_hashes(event_attrs, room_version) do
    with {:ok, content_hash} <- Events.content_hash(event_attrs, room_version),
         event_attrs = Map.put(event_attrs, "hashes", %{"sha256" => content_hash}),
         {:ok, event_id} <- Events.reference_hash(event_attrs, room_version) do
      {:ok, Map.put(event_attrs, "id", event_id)}
    end
  end

  defp select_auth_events(state_mapping, room_version, event_attrs) do
    keys = [{"m.room.power_levels", ""}]

    keys = if room_version in ~w|1 2 3 4 5 6 7 8 9 10 11|, do: [{"m.room.create", ""} | keys], else: keys

    keys =
      if event_attrs["sender"] != event_attrs["state_key"],
        do: [{"m.room.member", event_attrs["sender"]} | keys],
        else: keys

    keys =
      if event_attrs["type"] == "m.room.member" do
        # TODO: check if room version actually supports restricted rooms
        keys =
          if sk = Map.get(event_attrs["content"], "join_authorised_via_users_server"),
            do: [{"m.room.member", sk} | keys],
            else: keys

        cond do
          match?(%{"membership" => "invite", "third_party_invite" => _}, event_attrs["content"]) ->
            [
              {"m.room.member", event_attrs["state_key"]},
              {"m.room.join_rules", ""},
              {"m.room.third_party_invite", get_in(event_attrs, ~w[content third_party_invite signed token])} | keys
            ]

          event_attrs["content"]["membership"] in ~w[join invite] ->
            [{"m.room.member", event_attrs["state_key"]}, {"m.room.join_rules", ""} | keys]

          :else ->
            [{"m.room.member", event_attrs["state_key"]} | keys]
        end
      else
        keys
      end

    for key <- keys, is_map_key(state_mapping, key), do: state_mapping[key]
  end

  defp authorized?(state_mapping, room_version, event, auth_event_pdus) do
    RoomVersion.authorized?(room_version, event, state_mapping, auth_event_pdus)
  end
end
