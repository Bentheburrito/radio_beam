defmodule RadioBeam.PDU.Table do
  @moduledoc """
  ❗This is a private module intended to only be used by PDU and QLC query 
  modules.
  """

  alias RadioBeam.Repo
  alias RadioBeam.PDU

  @attrs [
    :primary_key,
    :arrival_key,
    :event_id,
    :auth_events,
    :content,
    :current_visibility,
    :hashes,
    :origin_server_ts,
    :parent_id,
    :prev_events,
    :sender,
    :signatures,
    :state_events,
    :state_key,
    :type,
    :unsigned
  ]

  use Memento.Table,
    attributes: @attrs,
    index: [:arrival_key, :event_id, :parent_id, :origin_server_ts],
    type: :ordered_set

  @doc """
  Persist a PDU to the Mnesia table. Must be run inside a transaction.
  """
  @spec persist(PDU.t()) :: :ok | {:error, any()}
  def persist(%PDU{} = pdu) do
    record =
      struct(
        %__MODULE__{
          primary_key: {pdu.room_id, pdu.chunk, pdu.depth, pdu.arrival_time, pdu.arrival_order},
          arrival_key: {pdu.arrival_time, pdu.arrival_order}
        },
        Map.from_struct(pdu)
      )

    Repo.one_shot(fn ->
      case Memento.Query.write(record) do
        %__MODULE__{} -> {:ok, pdu}
      end
    end)
  end

  ### MISC HELPERS / GETTERS ###

  @doc """
  Selects a raw PDU.Table tuple record by its event ID
  """
  @spec get(String.t()) :: {:ok, PDU.t()} | {:error, any()}
  def get(event_id) do
    Repo.one_shot(fn ->
      case Memento.Query.select(__MODULE__, {:==, :event_id, event_id}, limit: 1, coerce: false) do
        {[record], _cont} -> {:ok, to_pdu(record)}
        {[], _cont} -> {:error, :not_found}
        :"$end_of_table" -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Selects all raw PDU.Table tuple records by their event IDs
  """
  @spec all([String.t()]) :: {:ok, [tuple()]} | {:error, any()}
  def all(ids) do
    match_head = __MODULE__.__info__().query_base
    match_spec = for id <- ids, do: {put_elem(match_head, 3, id), [], [:"$_"]}

    with {:ok, pdus, _cont} <- all_matching(match_spec), do: {:ok, pdus}
  end

  @doc """
  Similar to all, but returns all PDUs that match the given match spec or 
  continuation. The match spec must of course return the record (`:"$_"`)
  """
  @spec all_matching(
          match_spec :: :ets.match_spec() | :ets.continuation(),
          :forward | :backward,
          opts :: Memento.Query.options()
        ) ::
          {:ok, [PDU.t()], :ets.continuation() | :end} | {:error, any()}
  def all_matching(match_spec, dir \\ :forward, opts \\ [])

  def all_matching(match_spec, :forward, opts) when is_list(match_spec) do
    Repo.one_shot(fn ->
      case Memento.Query.select_raw(__MODULE__, match_spec, Keyword.put(opts, :coerce, false)) do
        :"$end_of_table" -> {:ok, [], :end}
        {[], continuation} -> {:ok, [], continuation}
        {[_ | _] = records, continuation} -> {:ok, Enum.map(records, &to_pdu/1), continuation}
        records when is_list(records) -> {:ok, Enum.map(records, &to_pdu/1), :end}
      end
    end)
  end

  # ...need mnesia:select_reverse
  def all_matching(match_spec, :backward, opts) when is_list(match_spec) do
    limit = Keyword.get(opts, :limit, 10)

    Repo.one_shot(fn ->
      case :mnesia.ets(fn -> :ets.select_reverse(__MODULE__, match_spec, limit) end) do
        :"$end_of_table" -> {:ok, [], :end}
        {[], continuation} -> {:ok, [], continuation}
        {[_ | _] = records, continuation} -> {:ok, Enum.map(records, &to_pdu/1), continuation}
        records when is_list(records) -> {:ok, Enum.map(records, &to_pdu/1), :end}
      end
    end)
  end

  def all_matching(continuation, _dir, opts) when elem(continuation, 0) == :mnesia_select do
    Repo.one_shot(fn ->
      case Memento.Query.select_continue(continuation, Keyword.put(opts, :coerce, false)) do
        :"$end_of_table" -> {:ok, [], :end}
        {[], continuation} -> {:ok, [], continuation}
        {[_ | _] = records, continuation} -> {:ok, Enum.map(records, &to_pdu/1), continuation}
        records when is_list(records) -> {:ok, Enum.map(records, &to_pdu/1), :end}
      end
    end)
  end

  # temp: just need this to manage the :mnesia.ets call until mnesia supports
  # select_reverse directly
  def all_matching(continuation, _dir, _opts) do
    Repo.one_shot(fn ->
      case :mnesia.ets(fn -> :ets.select_reverse(continuation) end) do
        :"$end_of_table" -> {:ok, [], :end}
        {[], continuation} -> {:ok, [], continuation}
        {[_ | _] = records, continuation} -> {:ok, Enum.map(records, &to_pdu/1), continuation}
        records when is_list(records) -> {:ok, Enum.map(records, &to_pdu/1), :end}
      end
    end)
  end

  @doc """
  Selects all PDUs whose `parent_id` is among the given `ids`.
  """
  def all_children(ids, room_id) do
    match_head = put_elem(__MODULE__.__info__().query_base, 1, {room_id, :_, :_, :_, :_})
    match_spec = for id <- ids, do: {put_elem(match_head, 9, id), [], [:"$_"]}

    Repo.one_shot(fn ->
      pdus =
        __MODULE__
        |> Memento.Query.select_raw(match_spec, coerce: false)
        |> Enum.map(&to_pdu/1)

      {:ok, pdus}
    end)
  end

  @spec to_pdu(tuple()) :: PDU.t()
  defp to_pdu(
         {__MODULE__, {room_id, chunk, depth, arrival_time, arrival_order}, {arrival_time, arrival_order}, event_id,
          auth_events, content, current_visibility, hashes, os_ts, parent_id, prev_events, sender, signatures,
          state_events, state_key, type, unsigned}
       ) do
    %PDU{
      arrival_time: arrival_time,
      arrival_order: arrival_order,
      auth_events: auth_events,
      chunk: chunk,
      content: content,
      current_visibility: current_visibility,
      depth: depth,
      event_id: event_id,
      hashes: hashes,
      origin_server_ts: os_ts,
      parent_id: parent_id,
      prev_events: prev_events,
      room_id: room_id,
      sender: sender,
      signatures: signatures,
      state_events: state_events,
      state_key: state_key,
      type: type,
      unsigned: unsigned
    }
  end
end
