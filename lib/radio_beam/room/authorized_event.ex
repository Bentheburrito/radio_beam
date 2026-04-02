defmodule RadioBeam.Room.AuthorizedEvent do
  @moduledoc """
  A validated and authorized room message event.
  """

  @attrs ~w|auth_events content id origin_server_ts room_id sender state_key type unsigned prev_event_ids prev_state_content|a
  @enforce_keys @attrs
  defstruct @attrs
  @type t() :: %__MODULE__{}

  def new!(event_attrs) do
    struct!(__MODULE__,
      auth_events: Map.fetch!(event_attrs, "auth_events"),
      content: Map.fetch!(event_attrs, "content"),
      id: Map.fetch!(event_attrs, "id"),
      origin_server_ts: Map.fetch!(event_attrs, "origin_server_ts"),
      prev_event_ids: Map.fetch!(event_attrs, "prev_events"),
      prev_state_content: Map.get(event_attrs, "prev_state_content", :none),
      room_id: Map.fetch!(event_attrs, "room_id"),
      sender: Map.fetch!(event_attrs, "sender"),
      state_key: Map.get(event_attrs, "state_key", :none),
      type: Map.fetch!(event_attrs, "type"),
      unsigned: Map.get(event_attrs, "unsigned", %{})
    )
  end

  def keys, do: @attrs

  defimpl Polyjuice.Util.RoomEvent do
    alias RadioBeam.Room.AuthorizedEvent

    def get_content(%AuthorizedEvent{} = event), do: event.content
    def get_type(%AuthorizedEvent{} = event), do: event.type
    def get_sender(%AuthorizedEvent{} = event), do: event.sender
    def get_state_key(%AuthorizedEvent{state_key: :none}), do: nil
    def get_state_key(%AuthorizedEvent{} = event), do: event.state_key
    def get_prev_events(%AuthorizedEvent{} = event), do: event.prev_event_ids
    def get_room_id(%AuthorizedEvent{} = event), do: event.room_id
    def get_event_id(%AuthorizedEvent{} = event), do: event.id

    def get_redacts(%AuthorizedEvent{type: "m.room.redaction"} = event), do: event.content["redacts"]
    def get_redacts(%AuthorizedEvent{}), do: nil

    # TODO
    def get_signatures(%AuthorizedEvent{}), do: %{}

    def to_map(%AuthorizedEvent{} = event, room_version) do
      %{
        "auth_events" => event.auth_events,
        "content" => event.content,
        "event_id" => event.id,
        "origin_server_ts" => event.origin_server_ts,
        "prev_events" => event.prev_event_ids,
        "room_id" => event.room_id,
        "sender" => event.sender,
        "type" => event.type,
        "unsigned" => event.unsigned
      }
      |> put_state_key_if_not_none(event.state_key)
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

    @spec compute_content_hash(event :: AuthorizedEvent.t(), room_version :: String.t()) ::
            {:ok, binary} | :error
    def compute_content_hash(event, room_version) when is_supported(room_version) do
      try do
        {:ok, event_json_bytes} =
          event
          |> to_map(room_version)
          |> Map.drop(~w(signatures unsigned hashes))
          |> Polyjuice.Util.JSON.canonical_json()

        {:ok, :crypto.hash(:sha256, event_json_bytes)}
      rescue
        _ -> :error
      end
    end

    # credo:disable-for-lines:58 Credo.Check.Refactor.CyclomaticComplexity
    def redact(event, config) do
      content_keys_to_keep = Map.get(config.content, event.type, [])

      if content_keys_to_keep == :all do
        put_in(event.unsigned, %{})
      else
        # since Map.take doesn't support nested keys, we parse them and
        # rebuild the content manually
        new_content =
          content_keys_to_keep
          |> Stream.map(fn
            key when is_binary(key) -> [key]
            path when is_list(path) -> path
          end)
          |> Enum.reduce(%{}, fn path, new_content ->
            put_in(
              new_content,
              Enum.map(path, &Access.key(&1, %{})),
              get_in(event.content, path)
            )
          end)

        struct!(event, unsigned: %{}, content: new_content)
      end
    end
  end
end
