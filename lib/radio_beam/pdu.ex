defmodule RadioBeam.PDU do
  @moduledoc """
  A Persistent Data Unit described in room versions 3-10, representing an 
  event on the graph.
  """
  @behaviour Access

  @schema %{
    arrival_time: :integer,
    arrival_order: :integer,
    auth_events: {:array, :string},
    chunk: :integer,
    content: :map,
    current_visibility: :string,
    depth: :integer,
    event_id: :string,
    hashes: :map,
    origin_server_ts: :integer,
    parent_id: :string,
    prev_events: {:array, :string},
    room_id: :string,
    sender: :string,
    signatures: :map,
    state_events: {:array, :string},
    state_key: :string,
    type: :string,
    unsigned: :map
  }
  def schema, do: @schema

  @derive {Jason.Encoder, except: [:current_visibility, :arrival_time, :arrival_order]}
  defstruct Map.keys(@schema)

  @type event_id :: String.t()
  @type room_id :: String.t()

  @type t() :: %__MODULE__{
          arrival_time: non_neg_integer(),
          arrival_order: integer(),
          auth_events: [event_id()],
          chunk: non_neg_integer(),
          content: map(),
          current_visibility: String.t(),
          depth: non_neg_integer(),
          event_id: event_id(),
          hashes: map(),
          origin_server_ts: non_neg_integer(),
          parent_id: event_id(),
          prev_events: [event_id()],
          room_id: room_id(),
          sender: RadioBeam.User.id(),
          signatures: %{String.t() => any()},
          state_events: Polyjuice.Util.RoomVersion.state(),
          state_key: RadioBeam.User.id() | String.t() | nil,
          type: String.t(),
          unsigned: map()
        }

  defdelegate fetch(term, key), to: Map
  defdelegate get(term, key, default), to: Map
  defdelegate pop(term, key), to: Map
  defdelegate get_and_update(term, key, fun), to: Map

  @doc """
  Compares 2 PDUs according to their topological ordering. This function will
  raise a FunctionClauseError if the PDUs do not belong to the same room.

  Ties in topological order will be broken through stream/arrival ordering.
  """
  @spec compare(t(), t()) :: :gt | :lt | :eq
  def compare(%__MODULE__{room_id: room_id} = pdu1, %__MODULE__{room_id: room_id} = pdu2) do
    pdu1_key = {pdu1.chunk, pdu1.depth, pdu1.arrival_time, pdu1.arrival_order}
    pdu2_key = {pdu2.chunk, pdu2.depth, pdu2.arrival_time, pdu2.arrival_order}

    cond do
      pdu1_key == pdu2_key -> :eq
      pdu1_key > pdu2_key -> :gt
      :else -> :lt
    end
  end

  @cs_event_keys [:content, :event_id, :origin_server_ts, :room_id, :sender, :state_key, :type, :unsigned]
  @doc """
  Returns a PDU in the format expected by the Client-Server API
  """
  def to_event(pdu, room_version, keys \\ :atoms, format \\ :client)

  def to_event(%__MODULE__{} = pdu, room_version, :strings, format) do
    pdu |> to_event(room_version, :atoms, format) |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  def to_event(%__MODULE__{} = pdu, room_version, :atoms, :client) do
    pdu
    |> Map.take(@cs_event_keys)
    |> adjust_redacts_key(room_version)
    |> case do
      %{state_key: nil} = event -> Map.delete(event, :state_key)
      event -> event
    end
  end

  def to_event(%__MODULE__{} = pdu, room_version, :atoms, :federation) do
    pdu
    |> adjust_redacts_key(room_version)
    |> Map.from_struct()
    |> case do
      %{state_key: nil} = event -> Map.delete(event, :state_key)
      event -> event
    end
  end

  @pre_v11_format_versions ~w|1 2 3 4 5 6 7 8 9 10|
  defp adjust_redacts_key(%{type: "m.room.redaction"} = event, room_version)
       when room_version in @pre_v11_format_versions do
    {redacts, content} = Map.pop!(event.content, "redacts")

    event
    |> Map.put(:redacts, redacts)
    |> Map.put(:content, content)
  end

  defp adjust_redacts_key(event, _room_version), do: event

  defimpl Polyjuice.Util.RoomEvent do
    alias RadioBeam.PDU

    def get_content(%PDU{} = pdu), do: pdu.content
    def get_type(%PDU{} = pdu), do: pdu.type
    def get_sender(%PDU{} = pdu), do: pdu.sender
    def get_state_key(%PDU{} = pdu), do: pdu.state_key
    def get_prev_events(%PDU{} = pdu), do: pdu.prev_events
    def get_room_id(%PDU{} = pdu), do: pdu.room_id
    def get_event_id(%PDU{} = pdu), do: pdu.event_id

    def get_redacts(%PDU{type: "m.room.redaction"} = pdu), do: pdu.content["redacts"]
    def get_redacts(%PDU{}), do: nil

    def to_map(%PDU{} = pdu, room_version), do: PDU.to_event(pdu, room_version, :strings, :federation)

    @supported_versions Polyjuice.Util.RoomVersion.supported_versions()
    defguardp is_supported(version) when version in @supported_versions

    @spec compute_content_hash(pdu :: PDU.t(), room_version :: String.t()) ::
            {:ok, binary} | :error
    def compute_content_hash(pdu, room_version) when is_supported(room_version) do
      try do
        {:ok, event_json_bytes} =
          pdu
          |> to_map(room_version)
          |> Map.drop(~w(signatures unsigned hashes))
          |> Polyjuice.Util.JSON.canonical_json()

        {:ok, :crypto.hash(:sha256, event_json_bytes)}
      rescue
        _ -> :error
      end
    end

    def compute_reference_hash(pdu, room_version) when is_supported(room_version) do
      with {:ok, redacted} <- redact(pdu, room_version),
           {:ok, event_json_bytes} <-
             redacted
             |> to_map(room_version)
             |> Map.drop(~w(signatures age_ts unsigned))
             |> Polyjuice.Util.JSON.canonical_json() do
        {:ok, :crypto.hash(:sha256, event_json_bytes)}
      else
        _ -> :error
      end
    end

    @default_power_levels_keys ~w|ban events events_default kick redact state_default users users_default|

    def redact(pdu, room_version) when is_supported(room_version) do
      content_keys_to_keep =
        case pdu.type do
          "m.room.member" ->
            cond do
              room_version in ~w|1 2 3 4 5 6 7 8| ->
                ~w|membership|

              room_version in ~w|9 10| ->
                ~w|membership join_authorised_via_users_server|

              room_version == "11" ->
                ~w|membership join_authorised_via_users_server third_party_invite.signed|
            end

          "m.room.create" ->
            if room_version in ~w|1 2 3 4 5 6 7 8 9 10|, do: ~w|creator|, else: :all

          "m.room.join_rules" ->
            if room_version in ~w|1 2 3 4 5 6 7|, do: ~w|join_rule|, else: ~w|join_rule allow|

          "m.room.power_levels" ->
            if room_version in ~w|1 2 3 4 5 6 7 8 9 10|,
              do: @default_power_levels_keys,
              else: ["invite" | @default_power_levels_keys]

          "m.room.aliases" ->
            if room_version in ~w|1 2 3 4 5|, do: ~w|aliases|, else: []

          "m.room.history_visibility" ->
            ~w|history_visibility|

          "m.room.redaction" ->
            if room_version in ~w|1 2 3 4 5 6 7 8 9 10|, do: [], else: ~w|redacts|

          _ ->
            []
        end

      if content_keys_to_keep == :all do
        {:ok, put_in(pdu.unsigned, %{})}
      else
        # since Map.take doesn't support nested keys, we parse them and
        # rebuild the content manually
        new_content =
          content_keys_to_keep
          |> Stream.map(&String.split(&1, "."))
          |> Enum.reduce(%{}, fn path, new_content ->
            put_in(
              new_content,
              Enum.map(path, &Access.key(&1, %{})),
              get_in(pdu.content, path)
            )
          end)

        {:ok, %PDU{pdu | unsigned: %{}, content: new_content}}
      end
    end

    def redact(_unknown_version, _event), do: :error
  end
end
