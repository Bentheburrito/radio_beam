defmodule RadioBeam.Transaction do
  @moduledoc """
  Transactions are used to make sure Matrix requests are idempotent.

  TODO: This simple GenServer should later be replaced with something that 
  scales better. For room endpoints, txn_id could be passed to `send/4`
  """

  use GenServer

  require Logger

  ### API ###

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @timeout 12000
  @doc """
  Begins a transaction for a request from a specific device. Returns a handle 
  for the transaction. Must call `done/2` with the handle and the result of the
  operation within a reasonable amount of time.
  """
  def begin(txn_id, device_id, endpoint) do
    GenServer.call(__MODULE__, {:begin, txn_id, device_id, endpoint}, @timeout)
  end

  @doc """
  Ends a transaction. The `handle` should be a handle previously returned by
  `begin/3`.
  """
  def done(handle, response) do
    GenServer.call(__MODULE__, {:done, handle, response})
  end

  ### IMPL ###

  @impl GenServer
  def init(init_arg), do: {:ok, init_arg}

  @impl GenServer
  def handle_call({:begin, txn_id, device_id, endpoint}, from, state) do
    key = {txn_id, device_id, endpoint}

    case Map.fetch(state, key) do
      :error ->
        {:reply, {:ok, key}, Map.put(state, key, {:waiting, []})}

      {:ok, {:waiting, waiting}} ->
        {:noreply, Map.put(state, key, {:waiting, [from | waiting]})}

      {:ok, response} ->
        {:reply, {:already_done, response}, state}
    end
  end

  @impl GenServer
  def handle_call({:done, key, response}, _from, state) when is_map_key(state, key) do
    {:waiting, waiting} = Map.fetch!(state, key)

    for from <- waiting, do: GenServer.reply(from, response)

    {:reply, :ok, Map.put(state, key, response)}
  end
end
