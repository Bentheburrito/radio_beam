defmodule RadioBeam.Repo.Tables.PDU do
  @attrs [:primary_key, :arrival_key, :event_id, :parent_id, :origin_server_ts, :pdu]

  use Memento.Table,
    attributes: @attrs,
    index: [:arrival_key, :event_id, :parent_id, :origin_server_ts],
    type: :ordered_set

  require Record
  Record.defrecordp(:pdu_record, __MODULE__, @attrs)

  alias RadioBeam.PDU
  alias RadioBeam.Repo

  @doc """
  Selects a raw PDU.Table tuple record by its event ID
  """
  @spec fetch(String.t(), Keyword.t()) :: {:ok, PDU.t()} | {:error, any()}
  def fetch(event_id, _opts) do
    match_head = __MODULE__.__info__().query_base
    match_spec = [{put_elem(match_head, 3, event_id), [], [:"$_"]}]

    Repo.transaction(fn ->
      case Memento.Query.select_raw(__MODULE__, match_spec, limit: 1, coerce: false) do
        {[record], _cont} -> {:ok, pdu_record(record, :pdu)}
        {[], _cont} -> {:error, :not_found}
        [] -> {:error, :not_found}
        :"$end_of_table" -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Selects all raw PDU.Table tuple records by their event IDs
  """
  @spec get_all([String.t()], Keyword.t()) :: {:ok, [PDU.t()]} | {:error, any()}
  def get_all(ids, _opts) do
    match_head = __MODULE__.__info__().query_base
    match_spec = for id <- ids, do: {put_elem(match_head, 3, id), [], [:"$_"]}

    with {:ok, pdus, _cont} <- select(match_spec, dir: :forward), do: {:ok, pdus}
  end

  @doc """
  Similar to get_all, but returns all PDUs that match the given match spec or 
  continuation. The match spec must of course return the record (`:"$_"`)

  Pass `dir: :backward` to traverse the table from the end instead of the front.
  """
  def select(match_spec, opts) do
    dir = Keyword.get(opts, :dir, :forward)
    select(match_spec, dir, opts)
  end

  @spec select(
          match_spec :: :ets.match_spec() | :ets.continuation(),
          :forward | :backward,
          opts :: Memento.Query.options() | [dir: :forward | :backward]
        ) ::
          {:ok, [PDU.t()], :ets.continuation() | :end} | {:error, any()}
  defp select(match_spec, :forward, opts) when is_list(match_spec) do
    Repo.transaction(fn ->
      case Memento.Query.select_raw(__MODULE__, match_spec, Keyword.put(opts, :coerce, false)) do
        :"$end_of_table" -> {:ok, [], :end}
        {[], continuation} -> {:ok, [], continuation}
        {[_ | _] = records, continuation} -> {:ok, Enum.map(records, &pdu_record(&1, :pdu)), continuation}
        records when is_list(records) -> {:ok, Enum.map(records, &pdu_record(&1, :pdu)), :end}
      end
    end)
  end

  # ...need mnesia:select_reverse
  defp select(match_spec, :backward, opts) when is_list(match_spec) do
    limit = Keyword.get(opts, :limit, 10)

    Repo.transaction(fn ->
      case :mnesia.ets(fn -> :ets.select_reverse(__MODULE__, match_spec, limit) end) do
        :"$end_of_table" -> {:ok, [], :end}
        {[], continuation} -> {:ok, [], continuation}
        {[_ | _] = records, continuation} -> {:ok, Enum.map(records, &pdu_record(&1, :pdu)), continuation}
        records when is_list(records) -> {:ok, Enum.map(records, &pdu_record(&1, :pdu)), :end}
      end
    end)
  end

  defp select(continuation, _dir, opts) when elem(continuation, 0) == :mnesia_select do
    Repo.transaction(fn ->
      case Memento.Query.select_continue(continuation, Keyword.put(opts, :coerce, false)) do
        :"$end_of_table" -> {:ok, [], :end}
        {[], continuation} -> {:ok, [], continuation}
        {[_ | _] = records, continuation} -> {:ok, Enum.map(records, &pdu_record(&1, :pdu)), continuation}
        records when is_list(records) -> {:ok, Enum.map(records, &pdu_record(&1, :pdu)), :end}
      end
    end)
  end

  # temp: just need this to manage the :mnesia.ets call until mnesia supports
  # select_reverse directly
  defp select(continuation, _dir, _opts) do
    Repo.transaction(fn ->
      case :mnesia.ets(fn -> :ets.select_reverse(continuation) end) do
        :"$end_of_table" -> {:ok, [], :end}
        {[], continuation} -> {:ok, [], continuation}
        {[_ | _] = records, continuation} -> {:ok, Enum.map(records, &pdu_record(&1, :pdu)), continuation}
        records when is_list(records) -> {:ok, Enum.map(records, &pdu_record(&1, :pdu)), :end}
      end
    end)
  end

  def insert(%PDU{} = pdu) do
    # TODO: merge chunks if inserting PDU fills in a gap!
    pdu_table_struct =
      struct!(__MODULE__,
        primary_key: {pdu.room_id, pdu.chunk, pdu.depth, pdu.arrival_time, pdu.arrival_order},
        arrival_key: {pdu.arrival_time, pdu.arrival_order},
        event_id: pdu.event_id,
        parent_id: pdu.parent_id,
        origin_server_ts: pdu.origin_server_ts,
        pdu: pdu
      )

    Repo.transaction(fn ->
      Memento.Query.write(pdu_table_struct)
      {:ok, pdu}
    end)
  end
end
