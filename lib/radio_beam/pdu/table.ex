defmodule RadioBeam.PDU.Table do
  @moduledoc """
  ❗This is a private module intended to only be used by PDU and QLC query 
  modules.
  """

  alias RadioBeam.PDU

  @attrs [
    :pk,
    :event_id,
    :auth_events,
    :content,
    :hashes,
    :prev_events,
    :prev_state,
    :sender,
    :signatures,
    :state_key,
    :type,
    :unsigned
  ]

  use Memento.Table,
    attributes: @attrs,
    index: [:event_id],
    type: :ordered_set

  @type t() :: %__MODULE__{}

  @doc """
  Casts a raw PDU.Table record into a PDU struct.
  """
  @spec to_pdu(tuple()) :: PDU.t()
  def to_pdu(
        {__MODULE__, {room_id, neg_depth, os_ts}, event_id, auth_events, content, hashes, prev_events, prev_state,
         sender, signatures, state_key, type, unsigned}
      ) do
    %PDU{
      auth_events: auth_events,
      content: content,
      depth: -neg_depth,
      event_id: event_id,
      hashes: hashes,
      origin_server_ts: os_ts,
      prev_events: prev_events,
      prev_state: prev_state,
      room_id: room_id,
      sender: sender,
      signatures: signatures,
      state_key: state_key,
      type: type,
      unsigned: unsigned
    }
  end

  @spec from_pdu(PDU.t()) :: t()
  def from_pdu(%PDU{} = pdu) do
    struct(%__MODULE__{pk: {pdu.room_id, -pdu.depth, pdu.origin_server_ts}}, Map.from_struct(pdu))
  end

  @doc """
  Persist a PDU to the Mnesia table. Must be run inside a transaction.
  """
  @spec persist(PDU.t()) :: PDU.t() | no_return()
  def persist(%PDU{} = pdu) do
    record = from_pdu(pdu)

    case Memento.Query.write(record) do
      %__MODULE__{} -> pdu
    end
  end

  ### QUERIES ###

  # do nothing - traverse the table in desc order by default
  def order_by(query_handle, :descending), do: query_handle
  # note: mnesia traverses tables by erlang term order in ascending order, and
  # we don't have much control over that. 
  def order_by(query_handle, :ascending), do: :qlc.sort(query_handle, order: :descending)

  ### MISC HELPERS / GETTERS ###

  @doc """
  Gets the max depth of all the given event IDs. Returns -1 if the list is
  empty. This function needs to be run in a transaction
  """
  @spec max_depth_of_all(room_id :: String.t(), [event_id :: String.t()]) :: non_neg_integer()
  def max_depth_of_all(room_id, event_ids) do
    __MODULE__
    |> Memento.Query.select_raw(depth_ms(room_id, event_ids), coerce: false)
    |> Enum.min(&<=/2, fn -> 1 end)
    |> Kernel.-()
  end

  @doc """
  Gets the depth of the latest event `user_id` could see in the room based on
  their membership.
  """
  @spec get_depth_of_users_latest_join(room_id :: String.t(), user_id :: String.t()) :: non_neg_integer()
  def get_depth_of_users_latest_join(room_id, user_id) do
    fn ->
      Memento.Query.select_raw(__MODULE__, joined_after_ms(room_id, user_id), coerce: false, limit: 1)
    end
    |> Memento.transaction()
    |> case do
      {:ok, {[], _continuation}} -> -1
      {:ok, :"$end_of_table"} -> -1
      # minus one, because `depth` is the first event the user *can't* see,
      # since joined_after_ms examines prev_state
      {:ok, {[depth], _continuation}} -> -depth - 1
      {:error, _} -> -1
    end
  end

  @doc """
  Selects a raw PDU.Table tuple record by its event ID
  """
  @spec get_record(String.t()) :: {:ok, tuple()} | {:error, any()}
  def get_record(id) do
    fn -> Memento.Query.select(__MODULE__, {:==, :event_id, id}, limit: 1, coerce: false) end
    |> Memento.transaction()
    |> case do
      {:ok, {[record], _cont}} -> {:ok, record}
      {:ok, {[], _cont}} -> {:error, :not_found}
      {:ok, :"$end_of_table"} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Selects all raw PDU.Table tuple records by their event IDs
  """
  @spec get_all_records([String.t()]) :: {:ok, [tuple()]} | {:error, any()}
  def get_all_records(ids) do
    match_head = __MODULE__.__info__().query_base
    match_spec = for id <- ids, do: {put_elem(match_head, 2, id), [], [:"$_"]}

    fn -> Memento.Query.select_raw(__MODULE__, match_spec, coerce: false) end
    |> Memento.transaction()
    |> case do
      {:ok, records} when is_list(records) -> {:ok, records}
      {:ok, :"$end_of_table"} -> {:ok, []}
      {:error, error} -> {:error, error}
    end
  end

  ### MATCH SPECS ###

  defp depth_ms(room_id, event_ids) do
    for event_id <- event_ids do
      match_head = {__MODULE__, {room_id, :"$1", :_}, event_id, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_}
      {match_head, [], [:"$1"]}
    end
  end

  defp joined_after_ms(room_id, user_id) do
    match_head = {__MODULE__, {room_id, :"$1", :_}, :_, :_, :_, :_, :_, :"$2", :_, :_, :_, :_, :_}

    is_sender_member_key_present = {:is_map_key, {{"m.room.member", user_id}}, :"$2"}

    is_sender_joined =
      {:==, "join", {:map_get, "membership", {:map_get, "content", {:map_get, {{"m.room.member", user_id}}, :"$2"}}}}

    guards = [{:andalso, is_sender_member_key_present, is_sender_joined}]

    [{match_head, guards, [:"$1"]}]
  end
end
