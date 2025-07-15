defmodule RadioBeam.Repo.MatchSpecs.PDU do
  @moduledoc """
  Match specs for querying `Tables.PDU`

  TODO: expose the defrecordp in Tables.PDU and refactor these match specs to
  use that (and be more readable). OR consider a lib like matcha
  """

  alias RadioBeam.Repo.Tables.PDU

  @pdu :"$100"
  @chunk :"$101"
  @depth :"$102"
  @arrival_time :"$103"

  @doc """
  Selects all PDUs whose `parent_id` is among the given `ids`.
  """
  def get_all_children(event_ids, room_id) do
    match_head = put_elem(PDU.__info__().query_base, 1, {room_id, :_, :_, :_, :_})
    for id <- event_ids, do: {put_elem(match_head, 4, id), [], [:"$_"]}
  end

  @doc """
  Selects any `m.redaction` PDU that redacts the given `event_id`
  """
  def get_redaction(event_id, room_id) do
    match_head =
      PDU.__info__().query_base
      |> put_elem(1, {room_id, :_, :_, :_, :_})
      |> put_elem(5, @pdu)

    guards = [{:==, event_id, {:map_get, "redacts", {:map_set, :content, @pdu}}}]
    [{match_head, guards, [:"$_"]}]
  end

  @doc "Selects the first PDU in a room; the root node of the DAG."
  def root(room_id) do
    match_head = put_elem(PDU.__info__().query_base, 1, {room_id, 0, 1, :_, :_})
    [{match_head, [], [:"$_"]}]
  end

  @doc "When selecting backwards, selects the most recent PDUs in a room."
  def tip(room_id) do
    match_head = put_elem(PDU.__info__().query_base, 1, {room_id, :_, :_, :_, :_})
    [{match_head, [], [:"$_"]}]
  end

  @doc """
  Selects join membership PDUs for the given `user_id` that happened after the
  given `pdu`.
  """
  def next_join_after(%RadioBeam.PDU{} = pdu, room_id, user_id) do
    match_head =
      PDU.__info__().query_base
      |> put_elem(1, {room_id, @chunk, @depth, @arrival_time, :_})
      |> put_elem(6, @pdu)

    guards = [
      {:>=, @chunk, pdu.chunk},
      {:>=, @depth, pdu.depth},
      {:>=, @arrival_time, pdu.arrival_time},
      {:==, "join", {:map_get, "membership", {:map_get, :content, @pdu}}},
      {:==, user_id, {:map_get, :state_key, @pdu}}
    ]

    [{match_head, guards, [:"$_"]}]
  end

  @doc """
  Selects PDUs that occurred before/after (depending on the select dir) the
  given `timestamp`. If no events occurred within the given `cutoff_ms`, no
  PDUs will be returned.
  """
  def nearest_event(room_id, dir, timestamp, cutoff_ms) do
    match_head =
      PDU.__info__().query_base
      |> put_elem(1, {room_id, :_, :_, :_, :_})
      |> put_elem(6, @pdu)

    origin_server_ts = {:map_get, :origin_server_ts, @pdu}

    guards =
      case dir do
        :forward -> [{:>=, origin_server_ts, timestamp}, {:"=<", origin_server_ts, timestamp + cutoff_ms}]
        :backward -> [{:"=<", origin_server_ts, timestamp}, {:>=, origin_server_ts, timestamp - cutoff_ms}]
      end

    [{match_head, guards, [:"$_"]}]
  end

  @doc """
  Selects PDUs that occurred the given `since` tuple, including PDUs whose
  arrival time/order are equal to `since`.
  """
  def since(room_id, since) do
    match_head = put_elem(PDU.__info__().query_base, 1, {room_id, :_, :_, :_, :_})

    guards =
      case since do
        nil -> []
        _else -> [{:>, :"$2", {since}}]
      end

    [{match_head, guards, [:"$_"]}]
  end

  @doc """
  Selects PDUs according to their insertion into the DAG. Only selects PDUs
  that are a part of the given `chunk`
  """
  def traverse(room_id, chunk, guards) do
    match_head = put_elem(PDU.__info__().query_base, 1, {room_id, chunk, :"$1", :_, :_})
    [{match_head, guards, [:"$_"]}]
  end
end
