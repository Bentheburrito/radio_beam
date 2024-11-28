defmodule RadioBeam.PDU do
  @moduledoc """
  A Persistent Data Unit described in room versions 3-10, representing an 
  event on the graph.
  """
  @behaviour Access

  alias RadioBeam.PDU.Table

  require Logger

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

  defdelegate all(event_ids), to: Table
  defdelegate get(event_id), to: Table

  @doc """
  Returns a list of child PDUs of the given parent PDU. An event A is
  considered a child of event B if `A.content.["m.relates_to"].event_id == B.event_id`
  """
  def get_children(pdu, recurse_max \\ Application.fetch_env!(:radio_beam, :max_event_recurse))

  def get_children(%__MODULE__{} = pdu, recurse_max),
    do: get_children([pdu.event_id], pdu.room_id, recurse_max, Stream.map([], & &1))

  def get_children([%__MODULE__{room_id: room_id} | _] = pdus, recurse_max) when is_list(pdus),
    do: get_children(Enum.map(pdus, & &1.event_id), room_id, recurse_max, Stream.map([], & &1))

  # TODO: topological ordering
  defp get_children(_event_ids, _room_id, recurse, child_event_stream) when recurse <= 0,
    do: {:ok, Enum.to_list(child_event_stream)}

  defp get_children(event_ids, room_id, recurse, child_event_stream) do
    case Table.all_children(event_ids, room_id) do
      {:ok, []} ->
        {:ok, Enum.to_list(child_event_stream)}

      {:ok, child_pdus} ->
        more_child_events = Enum.reverse(child_pdus)

        # get the grandchildren
        get_children(
          Enum.map(more_child_events, & &1.event_id),
          room_id,
          recurse - 1,
          Stream.concat(child_event_stream, more_child_events)
        )

      error ->
        error
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
    |> case do
      %{state_key: nil} = event -> Map.delete(event, :state_key)
      event -> event
    end
  end

  @pre_v11_format_versions ~w|1 2 3 4 5 6 7 8 9 10|
  defp adjust_redacts_key(%{"type" => "m.room.redaction"} = event, room_version)
       when room_version in @pre_v11_format_versions do
    {redacts, content} = Map.pop!(event.content, "redacts")

    event
    |> Map.put(:redacts, redacts)
    |> Map.put(:content, content)
  end

  defp adjust_redacts_key(event, _room_version), do: event
end
