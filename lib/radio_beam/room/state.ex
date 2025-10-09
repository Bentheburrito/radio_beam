defmodule RadioBeam.Room.State do
  @moduledoc """
  This is a naive representation of room state that is not fit for federation.
  Will need to be reimplemented alongside state resolution v2 (and v3/Hydra
  when available in spec).

  With this impl, "state at an event" is the "latest" set of state events whose
  `stream_number` is <= the target PDU's `stream_number`. The `:mapping` takes
  the following form:

  ```elixir
  %{{type, state_key} => [%PDU{}, %PDU{}, …]}
  ```

  The invariant for the list of PDUs is: they are sorted in descending order by
  `stream_number`. i.e. PDUs are sorted from "most recent" to oldest

  NOTE: to avoid O(n) lookups for a particular state entry (where n is the
  number of events ever known under a certain key), could add an
  intermediate map between the mapping key and the PDU list(s). The map would be keyed by
  stream_numbers of a certain period (say, 100). That way a lookup would at
  most take 102 map/list reads (mapping key -> stream_number chunk -> find in list).
  Find the stream_number chunk by rounding down it to the nearest multiple of 100

  LATER: 
  maybe we can do a mapping like this:
  `%{{type, state_key} => %{lower_bound_state_group_number => [%PDU{}]}}`
  where lower_bound_state_group_number stores PDUs whose assigned state_group_number
  is rounded down to the nearest mult of 100 (i.e. `state_group_num - rem(state_group_num, 100)
  """
  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.PDU

  defstruct mapping: %{}
  @opaque t() :: %__MODULE__{mapping: %{{String.t(), String.t()} => [PDU.t()]}}

  def new!, do: %__MODULE__{}

  @spec authorize_event(t(), map()) ::
          {:ok, AuthorizedEvent.t()} | {:error, :unauthorized | :could_not_compute_reference_hash}
  def authorize_event(%__MODULE__{} = state, %{} = event_attrs) do
    auth_event_pdus = select_auth_events(state.mapping, event_attrs)
    room_version = room_version(state)

    # TODO: Polyjuice RoomState protocol
    state_mapping = Map.new(state.mapping, fn {key, [pdu | _]} -> {key, pdu} end)

    if authorized?(state_mapping, room_version, event_attrs, auth_event_pdus) do
      authz_event_attrs = Map.put(event_attrs, "auth_events", Enum.map(auth_event_pdus, & &1.event.id))

      with {:ok, event_id} <- Events.reference_hash(authz_event_attrs, room_version) do
        authz_event = authz_event_attrs |> Map.put("id", event_id) |> AuthorizedEvent.new!()
        {:ok, authz_event}
      end
    else
      {:error, :unauthorized}
    end
  end

  def room_version(%__MODULE__{} = state) do
    case fetch(state, "m.room.create", "") do
      {:ok, %{event: %{content: %{"room_version" => version}}}} -> version
      {:error, :not_found} -> RadioBeam.default_room_version()
    end
  end

  defp select_auth_events(state_mapping, event_attrs) do
    keys = [{"m.room.create", ""}, {"m.room.power_levels", ""}]

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

    for key <- keys, is_map_key(state_mapping, key), do: hd(state_mapping[key])
  end

  defp authorized?(state_mapping, room_version, event, auth_event_pdus) do
    RoomVersion.authorized?(room_version, event, state_mapping, auth_event_pdus)
  end

  def size(%__MODULE__{mapping: mapping}), do: map_size(mapping)

  def fetch(%__MODULE__{mapping: mapping}, type, state_key \\ "") do
    case Map.fetch(mapping, {type, state_key}) do
      {:ok, [%PDU{} = pdu | _]} -> {:ok, pdu}
      :error -> {:error, :not_found}
    end
  end

  def fetch_at(%__MODULE__{mapping: mapping}, type, state_key \\ "", %PDU{} = pdu) do
    case Map.fetch(mapping, {type, state_key}) do
      {:ok, pdu_list} -> find_pdu_at(pdu_list, pdu.stream_number)
      :error -> {:error, :not_found}
    end
  end

  # builds a sliding window of stream_number ranges where each state PDU in
  # pdu_list is the effective state event. Returns the effective state event
  # where `upper_bound > stream_number >= state_pdu.stream_number`
  defp find_pdu_at(pdu_list, stream_number) do
    [hd(pdu_list).stream_number + 1]
    |> Stream.concat(Stream.map(pdu_list, & &1.stream_number))
    |> Stream.zip(pdu_list)
    |> Enum.find_value({:error, :not_found}, fn {upper_bound_stream_num, %PDU{} = state_pdu} ->
      if stream_number in state_pdu.stream_number..(upper_bound_stream_num - 1), do: {:ok, state_pdu}
    end)
  end

  # normalizes to %{{type, state_key} => pdu}
  def get_all(%__MODULE__{} = state) do
    Map.new(state.mapping, fn {key, [pdu | _]} -> {key, pdu} end)
  end

  def get_all_at(%__MODULE__{} = state, %PDU{} = pdu) do
    Map.new(state.mapping, fn {{type, state_key}, _value} ->
      {:ok, state_pdu} = fetch_at(state, type, state_key, pdu)
      {{type, state_key}, state_pdu}
    end)
  end

  def replace_pdu!(%__MODULE__{} = state, %PDU{event: %{state_key: :none}}), do: state

  def replace_pdu!(%__MODULE__{mapping: mapping} = state, %PDU{event: %{id: event_id}} = pdu)
      when is_map_key(mapping, {pdu.event.type, pdu.event.state_key}) do
    update_in(state.mapping[{pdu.event.type, pdu.event.state_key}], fn pdu_list ->
      Enum.map(pdu_list, fn
        %PDU{event: %{id: ^event_id}} -> pdu
        pdu -> pdu
      end)
    end)
  end

  @stripped_state_types Enum.map(~w|create name avatar topic join_rules canonical_alias encryption|, &"m.room.#{&1}")
  @doc "Returns the stripped state of the given room."
  def get_invite_state_events(%__MODULE__{} = state, user_id) do
    # we additionally include the calling user's membership event
    @stripped_state_types
    |> Stream.map(&{&1, ""})
    |> Stream.concat([{"m.room.member", user_id}])
    |> Enum.reduce([], fn {type, state_key}, acc ->
      case fetch(state, type, state_key) do
        {:ok, pdu} -> [pdu | acc]
        {:error, :not_found} -> acc
      end
    end)
  end

  def user_has_power?(%__MODULE__{} = state, power_level_content_path, user_id, state_event? \\ false) do
    # TODO: Polyjuice RoomState protocol
    state_mapping = Map.new(state.mapping, fn {key, [pdu | _]} -> {key, pdu} end)
    RoomVersion.has_power?(user_id, power_level_content_path, state_event?, state_mapping)
  end

  def handle_pdu(%__MODULE__{} = state, %PDU{event: %AuthorizedEvent{state_key: :none}}), do: state

  def handle_pdu(%__MODULE__{} = state, %PDU{event: %AuthorizedEvent{state_key: sk}} = pdu) when is_binary(sk) do
    update_in(state.mapping[{pdu.event.type, pdu.event.state_key}], fn
      nil -> [pdu]
      pdu_list -> [pdu | pdu_list]
    end)
  end
end
