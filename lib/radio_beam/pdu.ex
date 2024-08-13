defmodule RadioBeam.PDU do
  @moduledoc """
  A Persistent Data Unit described in room versions 3-10, representing an 
  event on the graph.
  """

  alias :radio_beam_room_queries, as: Queries
  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.PDU.Table

  require Logger

  @derive {Jason.Encoder, except: [:prev_state]}
  defstruct [
    :auth_events,
    :content,
    :depth,
    :event_id,
    :hashes,
    :origin_server_ts,
    :prev_events,
    :prev_state,
    :room_id,
    :sender,
    :signatures,
    :state_key,
    :type,
    :unsigned
  ]

  @type event_id :: String.t()
  @type room_id :: String.t()

  @type t() :: %__MODULE__{
          auth_events: [event_id()],
          content: map(),
          depth: non_neg_integer(),
          event_id: event_id(),
          hashes: map(),
          origin_server_ts: non_neg_integer(),
          prev_events: [event_id()],
          prev_state: Polyjuice.Util.RoomVersion.state(),
          room_id: room_id(),
          sender: RadioBeam.User.id(),
          signatures: %{String.t() => any()},
          state_key: RadioBeam.User.id() | String.t() | nil,
          type: String.t(),
          unsigned: map()
        }

  defdelegate max_depth_of_all(room_id, event_ids), to: Table
  defdelegate get_depth_of_users_latest_join(room_id, user_id), to: Table
  defdelegate persist(pdu), to: Table

  @doc """
  Gets a PDU by its event ID.
  """
  @spec get(event_id :: String.t()) :: {:ok, t()} | {:error, any()}
  def get(event_id) do
    case Table.get_record(event_id) do
      {:ok, record} when is_tuple(record) -> {:ok, Table.to_pdu(record)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns `true` if the event is visible to the given user, else `false`.
  """
  @spec get_if_visible_to_user(event_id(), RadioBeam.User.id(), non_neg_integer() | :currently_joined) ::
          {:ok, t()} | {:error, :unauthorized | :internal}
  def get_if_visible_to_user(event_id, user_id, latest_joined_at_depth) do
    case Table.get_record(event_id) do
      {:ok, record} when is_tuple(record) ->
        if Queries.can_view_event(user_id, latest_joined_at_depth, record) do
          {:ok, Table.to_pdu(record)}
        else
          {:error, :unauthorized}
        end

      {:error, error} ->
        Logger.error("Failed to get a PDU record: #{inspect(error)}")
        {:error, :internal}
    end
  end

  @doc """
  Get a list of PDUs by their event IDs
  """
  @spec all(event_ids :: [String.t()]) :: {:ok, [t()]} | {:error, any()}
  def all(event_ids) do
    case Table.get_all_records(event_ids) do
      {:ok, records} -> {:ok, Enum.map(records, &Table.to_pdu(&1))}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Events began using the URL-safe variant in Room Version 4.

  It's not planned to support Room Versions 1 or 2 currently, since they
  have a completely different (non-hash-based) schema for event IDs that 
  include the servername.
  """
  def encode_reference_hash("3", hash), do: Base.encode64(hash)
  def encode_reference_hash(_room_version, hash), do: Base.url_encode64(hash)

  @pre_v11_format_versions ~w|1 2 3 4 5 6 7 8 9 10|
  def new(params, room_version) do
    now = :os.system_time(:millisecond)

    params =
      params
      |> Map.put("origin_server_ts", now)
      # TOIMPL
      |> Map.put("hashes", %{})
      |> Map.put("signatures", %{})
      |> Map.put("unsigned", %{})

    with {:ok, hash} <- RoomVersion.compute_reference_hash(room_version, Map.delete(params, "prev_state")) do
      content = Map.fetch!(params, "content")
      # %PDU{} has the V11 shape, but we want to be backwards-compatible with older versions
      content =
        if params["type"] == "m.room.redaction" and room_version not in @pre_v11_format_versions do
          Map.put_new_lazy(content, "redacts", fn -> Map.fetch!(params, "redacts") end)
        else
          content
        end

      {:ok,
       %__MODULE__{
         auth_events: Map.fetch!(params, "auth_events"),
         content: content,
         depth: Map.fetch!(params, "depth"),
         event_id: "$#{encode_reference_hash(room_version, hash)}",
         hashes: Map.fetch!(params, "hashes"),
         origin_server_ts: now,
         prev_events: Map.fetch!(params, "prev_events"),
         prev_state: Map.fetch!(params, "prev_state"),
         room_id: Map.fetch!(params, "room_id"),
         sender: Map.fetch!(params, "sender"),
         signatures: Map.fetch!(params, "signatures"),
         state_key: Map.get(params, "state_key"),
         type: Map.fetch!(params, "type"),
         unsigned: Map.fetch!(params, "unsigned")
       }}
    else
      :error -> {:error, :could_not_compute_ref_hash}
    end
  rescue
    e in KeyError -> {:error, {:required_param, e.key}}
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
    |> Map.delete(:prev_state)
    |> adjust_redacts_key(room_version)
    |> case do
      %{state_key: nil} = event -> Map.delete(event, :state_key)
      event -> event
    end
  end

  defp adjust_redacts_key(%{"type" => "m.room.redaction"} = event, room_version)
       when room_version in @pre_v11_format_versions do
    {redacts, content} = Map.pop!(event.content, "redacts")

    event
    |> Map.put(:redacts, redacts)
    |> Map.put(:content, content)
  end

  defp adjust_redacts_key(event, _room_version), do: event

  ### CURSORS ###

  @doc """
  Returns a cursor used to traverse a timeline in the given depth range.
  """
  @spec timeline_cursor(
          room_id(),
          RadioBeam.User.id(),
          map(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [RadioBeam.User.id()],
          :descending | :ascending
        ) :: :qlc.query_cursor()
  def timeline_cursor(room_id, user_id, tl_filter, max_depth, min_depth, latest_join_depth, ignored_sender_ids, order) do
    room_id
    |> Queries.timeline_from(user_id, tl_filter, max_depth, min_depth, latest_join_depth, ignored_sender_ids)
    |> Table.order_by(order)
    |> :qlc.cursor()
  end

  @spec nearest_event_cursor(
          room_id(),
          RadioBeam.User.id(),
          map(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          :descending | :ascending
        ) :: :qlc.query_cursor()
  def nearest_event_cursor(room_id, user_id, tl_filter, timestamp, cutoff, latest_join_depth, order) do
    query_fn =
      case order do
        :ascending -> &Queries.get_nearest_event_after/6
        :descending -> &Queries.get_nearest_event_before/6
      end

    room_id
    |> query_fn.(user_id, tl_filter, timestamp, cutoff, latest_join_depth)
    |> Table.order_by(order)
    |> :qlc.cursor()
  end

  @doc """
  Takes a cursor obtained from `timeline_cursor/8` and calls 
  `:qlc.next_answers/2` on it, returning a `Stream` of `PDU`s.
  """
  @spec next_answers(:qlc.query_cursor(), non_neg_integer(), :cleanup) :: Enumerable.t(t())
  def next_answers(qlc_cursor, limit, :cleanup) do
    answers = next_answers(qlc_cursor, limit)
    :ok = :qlc.delete_cursor(qlc_cursor)
    answers
  end

  def next_answers(qlc_cursor, limit) do
    qlc_cursor
    |> :qlc.next_answers(limit)
    |> Stream.map(&Table.to_pdu/1)
  end
end
