defmodule RadioBeam.PDU do
  @moduledoc """
  A Persistent Data Unit described in room versions 3-10, representing an 
  event on the graph.
  """

  alias Polyjuice.Util.RoomVersion

  @attrs [
    :pk,
    :event_id,
    :auth_events,
    :content,
    :hashes,
    :prev_events,
    :prev_state,
    :redacts,
    :sender,
    :signatures,
    :state_key,
    :type,
    :unsigned
  ]

  # @required @attrs -- [:redacts, :state_key, :unsigned]

  use Memento.Table,
    attributes: @attrs,
    index: [:event_id],
    type: :ordered_set

  @type t() :: %__MODULE__{}

  def room_id(%__MODULE__{pk: {room_id, _, _}}), do: room_id
  def depth(%__MODULE__{pk: {_, depth, _}}), do: -depth
  def origin_server_ts(%__MODULE__{pk: {_, _, origin_server_ts}}), do: origin_server_ts

  @doc """
  Get the max depth of all the given event IDs. Returns -1 if the list is
  empty. This function needs to be run in a transaction
  """
  def max_depth_of_all(room_id, event_ids) do
    __MODULE__
    |> Memento.Query.select_raw(depth_ms(room_id, event_ids), coerce: false)
    |> Enum.min(&<=/2, fn -> 1 end)
    |> Kernel.-()
  end

  defp depth_ms(room_id, event_ids) do
    for event_id <- event_ids do
      match_head = {__MODULE__, {room_id, :"$1", :_}, event_id, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_, :_}
      {match_head, [], [:"$1"]}
    end
  end

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

  defp joined_after_ms(room_id, user_id) do
    match_head = {__MODULE__, {room_id, :"$1", :_}, :_, :_, :_, :_, :_, :"$2", :_, :_, :_, :_, :_, :_}

    is_sender_member_key_present = {:is_map_key, {{"m.room.member", user_id}}, :"$2"}

    is_sender_joined =
      {:==, "join", {:map_get, "membership", {:map_get, "content", {:map_get, {{"m.room.member", user_id}}, :"$2"}}}}

    guards = [{:andalso, is_sender_member_key_present, is_sender_joined}]

    [{match_head, guards, [:"$1"]}]
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
       pk: {
         Map.fetch!(params, "room_id"),
         -Map.fetch!(params, "depth"),
         now
       },
       event_id: Map.fetch!(params, "event_id"),
       auth_events: Map.fetch!(params, "auth_events"),
       content: Map.fetch!(params, "content"),
       hashes: Map.fetch!(params, "hashes"),
       prev_events: Map.fetch!(params, "prev_events"),
       prev_state: Map.fetch!(params, "prev_state"),
       redacts: Map.get(params, "redacts"),
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

  @doc """
  Maps a collection of `event_id`s to PDUs
  """
  @spec get(Enumerable.t(String.t())) :: %{String.t() => t()}
  def get(ids, opts \\ []) do
    Memento.transaction!(fn ->
      # TODO: looked a bit but not an obvious way to do an `in` guard in match 
      #       specs/Memento/mnesia, though is `read`ing for each id a
      #       performance issue?
      for id <- ids, into: %{}, do: {id, hd(Memento.Query.select(__MODULE__, {:==, :event_id, id}, opts))}
    end)
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
    |> Map.put(:room_id, room_id(pdu))
    |> case do
      %{state_key: nil} = event -> Map.delete(event, :state_key)
      event -> event
    end
  end

  def to_event(%__MODULE__{} = pdu, :atoms, :federation) do
    pdu
    |> to_event(:atoms, :client)
    |> Map.put(:depth, depth(pdu))
    |> Map.put(:origin_server_ts, origin_server_ts(pdu))
  end
end