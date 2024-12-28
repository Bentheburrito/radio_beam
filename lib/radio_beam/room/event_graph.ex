defmodule RadioBeam.Room.EventGraph do
  @moduledoc """
  Functions for interacting with the a Room's DAG.

  Related spec reading:
  - https://github.com/matrix-org/matrix-spec/issues/1917
  - https://github.com/matrix-org/matrix-spec/issues/1334
  - https://github.com/matrix-org/gomatrixserverlib/issues/187
  - https://github.com/matrix-org/matrix-spec-proposals/pull/2716
  - https://github.com/matrix-org/matrix-spec/issues/852
  """

  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.Room.EventGraph.Core
  alias RadioBeam.Room.EventGraph.PaginationToken

  def max_events(type) when type in [:timeline, :state], do: Application.get_env(:radio_beam, :max_events)[type]

  ### CREATE / UPDATE DAG ###

  defdelegate append(room, parents, event_params), to: Core
  defdelegate redact_pdu(pdu, redaction_pdu, room_version), to: Core

  # TODO: merge chunks if this PDU fills in a gap!
  def persist_pdu(%PDU{} = pdu), do: PDU.Table.persist(pdu)

  ### READ DAG ###

  def root(room_id) do
    match_head = put_elem(PDU.Table.__info__().query_base, 1, {room_id, 0, 1, :_, :_})
    match_spec = [{match_head, [], [:"$_"]}]

    case PDU.Table.all_matching(match_spec, :forward, limit: 1) do
      {:ok, [%PDU{type: "m.room.create"} = root], _cont} -> {:ok, root}
      _ -> {:error, :not_found}
    end
  end

  def tip(room_id) do
    match_head = put_elem(PDU.Table.__info__().query_base, 1, {room_id, :_, :_, :_, :_})
    match_spec = [{match_head, [], [:"$_"]}]

    case PDU.Table.all_matching(match_spec, :backward) do
      {:ok, [%PDU{} = tip | _], _cont} -> {:ok, tip}
      _ -> {:error, :not_found}
    end
  end

  @chunk :"$100"
  @depth :"$101"
  @arrival_time :"$102"
  @content :"$103"
  def user_joined_after?(user_id, room_id, %PDU{} = pdu) do
    case Room.get_membership(room_id, user_id) do
      :not_found ->
        false

      %{"content" => %{"membership" => "join"}} ->
        true

      _not_joined_membership ->
        {:ok, state_events} = PDU.all(pdu.state_events)
        join_event? = &(&1.type == "m.room.member" and &1.state_key == user_id and &1.content["membership"] == "join")

        non_join_event? =
          &(&1.type == "m.room.member" and &1.state_key == user_id and &1.content["membership"] != "join")

        # TODO: break this conditional up/make it more clear...
        # if `pdu` is the user's non-join membership event, query the table
        # elseif it's their join membership, true
        # elseif it's any other pdu and its prev_state contains the user's join event, true
        # else query table
        if non_join_event?.(pdu) or (not join_event?.(pdu) and state_events |> Enum.find(join_event?) |> is_nil()) do
          match_head =
            PDU.Table.__info__().query_base
            |> put_elem(1, {room_id, @chunk, @depth, @arrival_time, :_})
            |> put_elem(5, @content)
            |> put_elem(14, user_id)

          guards = [
            {:>=, @chunk, pdu.chunk},
            {:>=, @depth, pdu.depth},
            {:>=, @arrival_time, pdu.arrival_time},
            {:==, "join", {:map_get, "membership", @content}}
          ]

          match_spec = [{match_head, guards, [:"$_"]}]

          case PDU.Table.all_matching(match_spec, :forward, limit: 1) do
            {:ok, [%PDU{}], _cont} -> true
            _ -> false
          end
        else
          true
        end
    end
  end

  @origin_server_ts :"$100"
  def get_nearest_event(room_id, dir, timestamp, cutoff_ms) do
    match_head =
      PDU.Table.__info__().query_base
      |> put_elem(1, {room_id, :_, :_, :_, :_})
      |> put_elem(8, @origin_server_ts)

    guards =
      case dir do
        :forward -> [{:>=, @origin_server_ts, timestamp}, {:"=<", @origin_server_ts, timestamp + cutoff_ms}]
        :backward -> [{:"=<", @origin_server_ts, timestamp}, {:>=, @origin_server_ts, timestamp - cutoff_ms}]
      end

    match_spec = [{match_head, guards, [:"$_"]}]

    case PDU.Table.all_matching(match_spec, dir, limit: 1) do
      {:ok, [], _cont} -> {:error, :not_found}
      {:ok, [pdu], :end} -> {:ok, pdu}
      {:ok, [pdu], cont} -> {:ok, pdu, cont}
    end
  end

  def get_nearest_event(continuation) do
    case PDU.Table.all_matching(continuation, _dir_does_not_matter = :forward, limit: 1) do
      {:ok, [], _cont} -> {:error, :not_found}
      {:ok, [pdu], :end} -> {:ok, pdu}
      {:ok, [pdu], cont} -> {:ok, pdu, cont}
    end
  end

  @doc """
  Gets the latest events on the graph since the given pagination token, up to
  `limit`.

  Note that while this will query events according to their "stream order", the
  returned events themselves may NOT be in stream order. If you need events in
  stream order (such as in incremental syncs), sort results by `{:arrival_time, :arrival_order}`.
  """
  def all_since(room_id, %PaginationToken{arrival_key: since} = token, limit \\ max_events(:timeline)) do
    match_head = put_elem(PDU.Table.__info__().query_base, 1, {room_id, :_, :_, :_, :_})
    match_spec = [{match_head, [{:>, :"$2", {since}}], [:"$_"]}]

    with {:ok, pdus, continuation} <- PDU.Table.all_matching(match_spec, :backward, limit: limit) do
      complete? =
        case continuation do
          :end ->
            true

          cont ->
            case PDU.Table.all_matching(cont) do
              {:ok, [], :end} -> true
              _ -> false
            end
        end

      case Enum.reverse(pdus) do
        [%PDU{} = oldest_pdu | _] = pdus -> {:ok, pdus, PaginationToken.new(oldest_pdu, :backward), complete?}
        [] -> {:ok, [], token, complete?}
      end
    end
  end

  @type from() :: :root | :tip | {PaginationToken.t() | PDU.event_id(), :forward | :backward}
  @type to() :: PDU.event_id() | :limit

  @doc """
  Traverses the DAG in topological order.

  Returns `{:ok, pdus, continuation}` on success, and `{:error, error}` if bad
  params are given. If the event graph has gaps that need to be backfilled
  before this query can be performed, `:missing_events` is returned.
  """
  @spec traverse(Room.id(), from(), to(), limit :: non_neg_integer()) ::
          {:ok, [PDU.t()], continuation()}
          | {:error, :not_found | :invalid_options | :ambiguous_token}
          | :missing_events
  def traverse(room_id, from \\ :tip, to \\ :limit, limit \\ max_events(:timeline))

  def traverse("!" <> _ = room_id, from, to, limit) do
    with {{:ok, from_pdu}, dir} <- parse_from(room_id, from),
         {:ok, to_pdu_or_limit} <- parse_to(to),
         :ok <- assert_no_gaps(from_pdu, to_pdu_or_limit),
         {:ok, guards} <- Core.build_window_guards(from_pdu, to_pdu_or_limit, dir) do
      match_head = put_elem(PDU.Table.__info__().query_base, 1, {room_id, from_pdu.chunk, :"$1", :_, :_})

      # pagination tokens point to the last known event. We include the 
      # `direction` used when this token was obtained, so they can act more
      # like a delimiter between "pages" of events, rather than blindly
      # excluding the head of the results under the assumption the client is
      # already aware of it. This only really ever poses a problem when
      # changing directions between queries (hence we only include the head
      # when `used_dir != dir`)
      include_head? =
        case from do
          {%PaginationToken{direction: used_dir}, _dir} -> used_dir != dir
          _ -> false
        end

      limit = if from in [:root, :tip] or include_head?, do: clamp_limit(limit), else: clamp_limit(limit) + 1

      from_event_id = from_pdu.event_id

      case do_traverse([{match_head, guards, [:"$_"]}], from_pdu.chunk, dir, limit) do
        {:ok, pdus, cont} when from in [:root, :tip] or include_head? -> {:ok, pdus, cont}
        {:ok, [%{event_id: ^from_event_id} | pdus], cont} -> {:ok, pdus, cont}
      end
    end
  end

  defp parse_from(room_id, :root), do: {root(room_id), :forward}
  defp parse_from(room_id, :tip), do: {tip(room_id), :backward}
  defp parse_from(_room_id, {"$" <> _ = event_id, dir}) when dir in [:backward, :forward], do: {PDU.get(event_id), dir}

  defp parse_from(room_id, {%PaginationToken{event_ids: event_ids}, dir}) when dir in [:backward, :forward] do
    with {:ok, pdus} <- PDU.all(event_ids),
         [%PDU{room_id: ^room_id} = pdu] <- Enum.filter(pdus, &(&1.room_id == room_id)) do
      {{:ok, pdu}, dir}
    else
      _ -> {:error, :ambiguous_token}
    end
  end

  defp parse_to(:limit), do: {:ok, :limit}
  defp parse_to("$" <> _ = event_id), do: PDU.get(event_id)

  @spec_suggested_default_limit 10
  defp clamp_limit(limit) when is_integer(limit), do: limit |> min(max_events(:timeline)) |> max(0)
  defp clamp_limit(_non_int_limit), do: @spec_suggested_default_limit

  # our invariant for the `chunk` value is: if two PDUs share the same chunk,
  # we have all of the events "between" them such that we can traverse the DAG
  # from one to the other. Otherwise we need to backfill the missing events
  defp assert_no_gaps(%{chunk: chunk}, %{chunk: chunk}), do: :ok
  # if we don't want to stop at a specific event, we'll just go to the end of
  # the chunk
  defp assert_no_gaps(_pdu1, :limit), do: :ok
  defp assert_no_gaps(_pdu1, _pdu2), do: :missing_events

  @typedoc """
  Describes how callers of `traverse/1` and `all_since/1` can continue to traverse
  the graph. Can be one of the following values:

  - `:root` - no more events; reached the beginning of the room.
  - `:tip` - no more events currently; reached the end of the room from the
    perspective of the homeserver.
  - `{:end_of_chunk, PaginationToken.t()}` - the homeserver doesn't have any
  more room history past the given token. Indicates the need to backfill.
  - `{:more, PaginationToken.t()} - we have more events, use the provided
    pagination token in the next call to continue.
  """
  @type continuation() ::
          :root | :tip | {:more, PaginationToken.t()} | {:end_of_chunk, PaginationToken.t()}

  @spec do_traverse(:ets.match_spec() | :ets.continuation(), non_neg_integer(), :forward | :backward, non_neg_integer()) ::
          {:ok, [PDU.t()], continuation()} | {:error, :not_found}
  defp do_traverse(match_spec_or_cont, chunk, dir, limit, pdus_acc \\ [])

  defp do_traverse(_match_spec_or_cont, _chunk, dir, limit, pdus_acc) when length(pdus_acc) >= limit do
    pdus = Enum.slice(pdus_acc, 0..limit)
    {:ok, pdus, {:more, next_token(pdus, pdus_acc, dir)}}
  end

  defp do_traverse(match_spec_or_cont, chunk, dir, limit, pdus_acc) do
    root_chunk? = chunk == 0

    RadioBeam.Repo.one_shot(fn ->
      case PDU.Table.all_matching(match_spec_or_cont, dir, limit: limit) do
        {:ok, pdus, :end} when dir == :forward and root_chunk? -> {:ok, pdus_acc ++ pdus, :tip}
        {:ok, pdus, :end} when dir == :backward and root_chunk? -> {:ok, pdus_acc ++ pdus, :root}
        {:ok, pdus, :end} -> {:ok, pdus_acc ++ pdus, {:end_of_chunk, next_token(pdus, pdus_acc, dir)}}
        {:ok, pdus, continuation} -> do_traverse(continuation, chunk, dir, limit, pdus_acc ++ pdus)
      end
    end)
  end

  defp next_token([], pdus_acc, dir), do: PaginationToken.new(List.last(pdus_acc), dir)
  defp next_token(pdus, _pdus_acc, dir), do: PaginationToken.new(List.last(pdus), dir)
end
