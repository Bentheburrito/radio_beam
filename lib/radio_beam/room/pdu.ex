defmodule RadioBeam.Room.PDU do
  alias RadioBeam.Room.AuthorizedEvent

  @attrs ~w|prev_event_ids event stream_number|a
  @enforce_keys @attrs
  defstruct @attrs
  @type t() :: %__MODULE__{}

  def new!(%AuthorizedEvent{} = event, prev_event_ids, stream_number) when is_list(prev_event_ids) do
    struct!(__MODULE__, prev_event_ids: prev_event_ids, event: event, stream_number: stream_number)
  end

  defimpl Polyjuice.Util.RoomEvent do
    alias RadioBeam.Room.PDU

    def get_content(%PDU{} = pdu), do: pdu.event.content
    def get_type(%PDU{} = pdu), do: pdu.event.type
    def get_sender(%PDU{} = pdu), do: pdu.event.sender
    def get_state_key(%PDU{event: %{state_key: :none}}), do: nil
    def get_state_key(%PDU{} = pdu), do: pdu.event.state_key
    def get_prev_events(%PDU{} = pdu), do: pdu.prev_event_ids
    def get_room_id(%PDU{} = pdu), do: pdu.event.room_id
    def get_event_id(%PDU{} = pdu), do: pdu.event.id

    def get_redacts(%PDU{event: %{type: "m.room.redaction"}} = pdu), do: pdu.event.content["redacts"]
    def get_redacts(%PDU{}), do: nil

    def to_map(%PDU{} = pdu, room_version) do
      %{
        "auth_events" => pdu.event.auth_events,
        "content" => pdu.event.content,
        "depth" => pdu.stream_number,
        "event_id" => pdu.event.id,
        "origin_server_ts" => pdu.event.origin_server_ts,
        "room_id" => pdu.event.room_id,
        "sender" => pdu.event.sender,
        "type" => pdu.event.type,
        "unsigned" => pdu.event.unsigned
      }
      |> put_state_key_if_not_none(pdu.event.state_key)
      |> adjust_redacts_key(room_version)
    end

    @pre_v11_format_versions ~w|1 2 3 4 5 6 7 8 9 10|
    defp adjust_redacts_key(%{"type" => "m.room.redaction"} = event_map, version)
         when version in @pre_v11_format_versions do
      {redacts, content} = Map.pop!(event_map.content, "redacts")

      event_map
      |> Map.put("redacts", redacts)
      |> Map.put("content", content)
    end

    defp adjust_redacts_key(event_map, _room_version), do: event_map

    defp put_state_key_if_not_none(event_map, :none), do: event_map

    defp put_state_key_if_not_none(event_map, state_key) when is_binary(state_key),
      do: Map.put(event_map, "state_key", state_key)

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
        case pdu.event.type do
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
        {:ok, put_in(pdu.event.unsigned, %{})}
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
              get_in(pdu.event.content, path)
            )
          end)

        {:ok, struct!(pdu, event: struct!(pdu.event, unsigned: %{}, content: new_content))}
      end
    end

    def redact(_unknown_version, _event), do: :error
  end
end
