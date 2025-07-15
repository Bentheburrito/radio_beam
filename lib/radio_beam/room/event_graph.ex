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
  alias RadioBeam.Repo.MatchSpecs
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.EventGraph.Core
  alias RadioBeam.Room.EventGraph.PaginationToken

  @type from() :: :root | :tip | {PaginationToken.t() | PDU.event_id(), :forward | :backward}

  @typedoc """
  Describes how a far a stream returned by `traverse/2` or `stream_all_since/2`
  will return events before it terminates. Can be one of the following values:

  - `:root` - no more events; reached the beginning of the room.
  - `:tip` - no more events currently; reached the end of the room from the
    perspective of the homeserver.
  - `:end_of_chunk` - the homeserver doesn't have any more room history past
  the given token. Indicates the need to backfill.
  """
  @type stream_ends_at() :: :root | :tip | :end_of_chunk

  def max_events(type) when type in [:timeline, :state], do: Application.get_env(:radio_beam, :max_events)[type]

  ### CREATE / UPDATE DAG ###

  defdelegate append(room, parents, event_params), to: Core
  defdelegate redact_pdu(pdu, redaction_pdu, room_version), to: Core

  ### READ DAG ###

  def root(room_id) do
    case Repo.select(PDU, MatchSpecs.PDU.root(room_id), limit: 1) do
      {:ok, [%PDU{type: "m.room.create"} = root], _cont} -> {:ok, root}
      _ -> {:error, :not_found}
    end
  end

  def tip(room_id) do
    case Repo.select(PDU, MatchSpecs.PDU.tip(room_id), dir: :backward, limit: 1) do
      {:ok, [%PDU{} = tip | _], _cont} -> {:ok, tip}
      _ -> {:error, :not_found}
    end
  end

  def get_nearest_event(room_id, dir, timestamp, cutoff_ms) do
    match_spec = MatchSpecs.PDU.nearest_event(room_id, dir, timestamp, cutoff_ms)

    case Repo.select(PDU, match_spec, dir: dir, limit: 1) do
      {:ok, [], _cont} -> {:error, :not_found}
      {:ok, [pdu], :end} -> {:ok, pdu}
      {:ok, [pdu], cont} -> {:ok, pdu, cont}
    end
  end

  def get_nearest_event(continuation) do
    case Repo.select(PDU, continuation, limit: 1) do
      {:ok, [], _cont} -> {:error, :not_found}
      {:ok, [pdu], :end} -> {:ok, pdu}
      {:ok, [pdu], cont} -> {:ok, pdu, cont}
    end
  end

  @doc """
  Returns a list of child PDUs of the given parent PDU. An event A is
  considered a child of event B if `A.content.["m.relates_to"].event_id == B.event_id`
  """
  def get_children(pdu, recurse_max \\ Application.fetch_env!(:radio_beam, :max_event_recurse))

  def get_children(%PDU{} = pdu, recurse_max),
    do: get_children([pdu.event_id], pdu.room_id, recurse_max, Stream.map([], & &1))

  def get_children([%PDU{room_id: room_id} | _] = pdus, recurse_max) when is_list(pdus),
    do: get_children(Enum.map(pdus, & &1.event_id), room_id, recurse_max, Stream.map([], & &1))

  # TODO: topological ordering
  defp get_children(_event_ids, _room_id, recurse, child_event_stream) when recurse <= 0,
    do: {:ok, Enum.to_list(child_event_stream)}

  defp get_children(event_ids, room_id, recurse, child_event_stream) do
    case Repo.select(PDU, MatchSpecs.PDU.get_all_children(event_ids, room_id)) do
      {:ok, [], _cont} ->
        {:ok, Enum.to_list(child_event_stream)}

      {:ok, child_pdus, _cont} ->
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

  @chunk_size 20
  @doc """
  Streams the latest events on the graph we received since the given pagination
  token.

  Note that while this will query events according to their "stream order", the
  returned events themselves may NOT be in stream order. If you need events in
  stream order (such as in incremental syncs), sort results by `{:arrival_time, :arrival_order}`.

  The Stream must be executed inside a Repo.transaction
  """
  def stream_all_since(room_id, since) do
    since =
      case since do
        %PaginationToken{arrival_key: since} -> since
        nil -> nil
      end

    match_spec = MatchSpecs.PDU.since(room_id, since)

    Stream.resource(
      fn -> Repo.select(PDU, match_spec, dir: :backward, limit: @chunk_size) end,
      &traverse_next_chunk/1,
      & &1
    )
  end

  @doc """
  Traverses the DAG in topological order.

  Returns `{:ok, pdu_stream, stream_ends_at}` on success, and `{:error, error}`
  if bad params are given.

  The Stream must be executed inside a Repo.transaction
  """
  @spec traverse(Room.id(), from()) ::
          {:ok, Enumerable.t(PDU.t()), stream_ends_at()} | {:error, :ambiguous_token}
  def traverse(room_id, from) do
    with {{:ok, from_pdu}, dir} <- parse_from(room_id, from) do
      guards = Core.build_window_guards(from_pdu, dir)
      spec = MatchSpecs.PDU.traverse(room_id, from_pdu.chunk, guards)

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

      event_stream =
        Stream.resource(fn -> Repo.select(PDU, spec, dir: dir, limit: @chunk_size) end, &traverse_next_chunk/1, & &1)

      event_stream = if from in [:root, :tip] or include_head?, do: event_stream, else: Stream.drop(event_stream, 1)

      root_chunk? = from_pdu.chunk == 0

      stream_ends_at =
        cond do
          dir == :forward and root_chunk? -> :tip
          dir == :backward and root_chunk? -> :root
          # we don't give a pagination token here - the caller has the info
          # they need to build a pagination token (using the last PDU from the
          # stream, + dir)
          :else -> :end_of_chunk
        end

      {:ok, event_stream, stream_ends_at}
    end
  end

  defp traverse_next_chunk({:ok, [], :end}), do: {:halt, nil}

  defp traverse_next_chunk({:ok, [], continuation}) do
    {:ok, pdus, continuation} = Repo.select(PDU, continuation)
    {pdus, {:ok, [], continuation}}
  end

  defp traverse_next_chunk({:ok, pdus, continuation}), do: {pdus, {:ok, [], continuation}}

  defp parse_from(room_id, :root), do: {root(room_id), :forward}
  defp parse_from(room_id, :tip), do: {tip(room_id), :backward}

  defp parse_from(_room_id, {"$" <> _ = event_id, dir}) when dir in [:backward, :forward],
    do: {Repo.fetch(PDU, event_id), dir}

  defp parse_from(room_id, {%PaginationToken{event_ids: event_ids}, dir}) when dir in [:backward, :forward] do
    with {:ok, pdus} <- Repo.get_all(PDU, event_ids),
         [%PDU{room_id: ^room_id} = pdu] <- Enum.filter(pdus, &(&1.room_id == room_id)) do
      {{:ok, pdu}, dir}
    else
      _ -> {:error, :ambiguous_token}
    end
  end

  @spec_suggested_default_limit 10
  defp clamp_limit(limit) when is_integer(limit), do: limit |> min(max_events(:timeline)) |> max(0)
  defp clamp_limit(_non_int_limit), do: @spec_suggested_default_limit

  # TODO: call this from Timeline
  # our invariant for the `chunk` value is: if two PDUs share the same chunk,
  # we have all of the events "between" them such that we can traverse the DAG
  # from one to the other. Otherwise we need to backfill the missing events
  def gap_between?(%{chunk: chunk1}, %{chunk: chunk2}), do: chunk1 != chunk2
end
