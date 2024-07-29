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
    :redacts,
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
          redacts: event_id() | nil,
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

  def new(params, room_version) do
    now = :os.system_time(:millisecond)

    params =
      params
      |> Map.put("origin_server_ts", now)
      # TOIMPL
      |> Map.put("hashes", %{})
      |> Map.put("signatures", %{})
      |> Map.put("unsigned", %{})
      |> then(
        &Map.put_new_lazy(&1, "event_id", fn ->
          case RoomVersion.compute_reference_hash(room_version, Map.delete(&1, "prev_state")) do
            {:ok, hash} -> "$#{Base.url_encode64(hash)}:#{RadioBeam.server_name()}"
            :error -> throw(:could_not_compute_ref_hash)
          end
        end)
      )

    {:ok,
     %__MODULE__{
       auth_events: Map.fetch!(params, "auth_events"),
       content: Map.fetch!(params, "content"),
       depth: Map.fetch!(params, "depth"),
       event_id: Map.fetch!(params, "event_id"),
       hashes: Map.fetch!(params, "hashes"),
       origin_server_ts: now,
       prev_events: Map.fetch!(params, "prev_events"),
       prev_state: Map.fetch!(params, "prev_state"),
       redacts: Map.get(params, "redacts"),
       room_id: Map.fetch!(params, "room_id"),
       sender: Map.fetch!(params, "sender"),
       signatures: Map.fetch!(params, "signatures"),
       state_key: Map.get(params, "state_key"),
       type: Map.fetch!(params, "type"),
       unsigned: Map.fetch!(params, "unsigned")
     }}
  rescue
    e in KeyError -> {:error, {:required_param, e.key}}
  catch
    e -> e
  end

  @cs_event_keys [:content, :event_id, :origin_server_ts, :room_id, :sender, :state_key, :type, :unsigned]
  @doc """
  Returns a PDU in the format expected by the Client-Server API
  """
  def to_event(pdu, keys \\ :atoms, format \\ :client)

  def to_event(%__MODULE__{} = pdu, :strings, format) do
    pdu |> to_event(:atoms, format) |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  def to_event(%__MODULE__{} = pdu, :atoms, :client) do
    pdu
    |> Map.take(@cs_event_keys)
    |> case do
      %{state_key: nil} = event -> Map.delete(event, :state_key)
      event -> event
    end
  end

  def to_event(%__MODULE__{} = pdu, :atoms, :federation) do
    pdu
    |> Map.delete(:prev_state)
    |> case do
      %{state_key: nil} = event -> Map.delete(event, :state_key)
      event -> event
    end
  end

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
