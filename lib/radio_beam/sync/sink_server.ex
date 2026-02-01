defmodule RadioBeam.Sync.SinkServer do
  @moduledoc """
  The "sink" process to which `Sync.Source` results are sent.

  A `SinkServer` orchestrates the `Task`s that call `RadioBeam.Sync.Source`
  implementations to fulfill a /sync request.

  A `SinkServer` will track each `Task`s progress and, once it has received at
  least one `:sync_*` message from each `Task`, return the aggregated results
  to each caller currently waiting for a reply via `sync_v2/1`.
  """
  use GenServer, restart: :transient

  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room.View
  alias RadioBeam.Sync.NextBatch
  alias RadioBeam.Sync.Source
  alias RadioBeam.User

  require Logger

  @attrs ~w|inputs sources_by_key source_keys_by_task_ref waiting_callers timeout_state|a
  @enforce_keys @attrs
  defstruct @attrs

  @default_timeout 0
  @max_timeout Application.compile_env!(:radio_beam, ~w|sync timeout|a)

  @registry RadioBeam.Sync.SinkRegistry
  @sink_supervisor RadioBeam.Sync.SinkServer.Supervisor
  @source_supervisor RadioBeam.Sync.Source.Supervisor

  @task_opts [
    shutdown: :brutal_kill
    # max_concurrency: Application.compile_env!(:radio_beam, ~w|sync concurrency|a),
    # on_timeout: :kill_task,
    # timeout: :infinity
  ]

  def start_link({%{} = inputs, _sources_by_key} = init_arg) do
    key = {inputs.user_id, inputs.device_id, Map.get(inputs, :full_last_batch)}
    GenServer.start_link(__MODULE__, init_arg, name: via(key))
  end

  def sync_v2(user_id, device_id, opts) do
    with {:ok, pid} <- start_sync_v2_if_dead(user_id, device_id, opts),
         do: GenServer.call(pid, :await_v2_results, @max_timeout)
  end

  defp start_sync_v2_if_dead(user_id, device_id, opts) do
    case User.get_device_info(user_id, device_id) do
      {:ok, _} ->
        case Registry.lookup(@registry, {user_id, device_id}) do
          [{pid, _}] -> {:ok, pid}
          _ -> with {:error, {:already_started, pid}} <- start_v2_sync(user_id, device_id, opts), do: {:ok, pid}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp start_v2_sync(user_id, device_id, opts) do
    {joined_room_ids, invited_room_ids} =
      case View.all_participating(user_id) do
        {:ok, participating} -> {Map.keys(participating.latest_known_join_pdus), MapSet.to_list(participating.invited)}
        {:error, :not_found} -> {[], []}
      end

    known_memberships = LazyLoadMembersCache.get(joined_room_ids, device_id)
    maybe_last_batch_token = Keyword.get(opts, :since)
    timeout = opts |> Keyword.get(:timeout, @default_timeout) |> min(@max_timeout)

    inputs = %{
      account_data: Keyword.fetch!(opts, :account_data),
      user_id: user_id,
      device_id: device_id,
      known_memberships: known_memberships,
      event_filter: Keyword.fetch!(opts, :filter),
      ignored_user_ids: Keyword.fetch!(opts, :ignored_user_ids),
      full_state?: Keyword.get(opts, :full_state?, false),
      timeout: timeout,
      full_last_batch: maybe_last_batch_token
    }

    sources_by_key =
      joined_room_ids
      |> Source.sync_v2_sources(invited_room_ids, maybe_last_batch_token)
      |> Map.new(&{&1.key, &1})

    @sink_supervisor.start_sink({inputs, sources_by_key})
  end

  @impl GenServer
  def init({%{} = inputs, sources_by_key}) do
    {timeout, inputs} = Map.pop!(inputs, :timeout)

    init_state = %__MODULE__{
      inputs: inputs,
      source_keys_by_task_ref: %{},
      sources_by_key: sources_by_key,
      timeout_state: {:running, Process.send_after(self(), :timeout, timeout)},
      waiting_callers: MapSet.new()
    }

    {:ok, init_state, {:continue, :start_tasks}}
  end

  @impl GenServer
  def handle_continue(:start_tasks, %__MODULE__{} = state) do
    sink_pid = self()

    keys_by_task_ref =
      for {key, %Source{} = source} <- state.sources_by_key, into: %{} do
        last_batch =
          with %NextBatch{} = full_last_batch <- state.inputs.full_last_batch,
               {:ok, last_batch} <- NextBatch.fetch(full_last_batch, key) do
            last_batch
          else
            _ -> nil
          end

        source_inputs =
          state.inputs
          |> Map.take(source.mod.inputs())
          |> Map.put(:last_batch, last_batch)

        ref =
          Task.Supervisor.async_nolink(@source_supervisor, Source, :run, [source, source_inputs, sink_pid], @task_opts)

        {ref, key}
      end

    {:noreply, put_in(state.source_keys_by_task_ref, keys_by_task_ref)}
  rescue
    e ->
      Logger.error(e)
      reraise e, __STACKTRACE__
  end

  @impl GenServer
  def handle_call(:await_v2_results, from, %__MODULE__{} = state) do
    state.waiting_callers
    |> update_in(&MapSet.put(&1, from))
    |> maybe_complete_sync()
  end

  @impl GenServer
  def handle_info({:sync_waiting, _} = message, %__MODULE__{} = state) do
    state
    |> handle_source_message(message)
    |> maybe_complete_sync()
  end

  @impl GenServer
  def handle_info({ref, {:sync_data, _, _, _} = message}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state.source_keys_by_task_ref
    |> update_in(&Map.delete(&1, ref))
    |> handle_source_message(message)
    |> maybe_complete_sync()
  end

  # task completed (called on both success or failed)
  @impl GenServer
  def handle_info({:DOWN, ref, _, _, reason}, state) do
    {key, state} = pop_in(state.source_keys_by_task_ref[ref])

    if reason != :normal do
      error =
        case reason do
          {exception, stacktrace} -> Exception.format(:error, exception, stacktrace)
          error -> inspect(error)
        end

      Logger.warning("A sync source task for #{state.inputs.user_id} failed with reason: #{error}")

      {:noreply, update_in(state.sources_by_key[key], &Source.put_no_update(&1))}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:timeout, state), do: state.timeout_state |> put_in(:timed_out) |> maybe_complete_sync()

  defp handle_source_message(%__MODULE__{} = state, {:sync_data, key, _result, _next} = message)
       when is_map_key(state.sources_by_key, key) do
    update_in(state.sources_by_key[key], &Source.handle_message(&1, message))
  end

  defp handle_source_message(%__MODULE__{} = state, {:sync_waiting, key} = message)
       when is_map_key(state.sources_by_key, key) do
    update_in(state.sources_by_key[key], &Source.handle_message(&1, message))
  end

  defp maybe_complete_sync(%__MODULE__{} = new_state) do
    if sync_state(new_state) == :done and not Enum.empty?(new_state.waiting_callers) do
      complete_sync(new_state)
    else
      {:noreply, new_state}
    end
  end

  defp sync_state(%__MODULE__{} = state) do
    sources = Stream.map(state.sources_by_key, fn {_, source} -> source end)

    cond do
      Enum.any?(sources, &(Source.state(&1) == :working)) -> :waiting
      Enum.all?(sources, &(Source.state(&1) == :waiting)) and state.timeout_state != :timed_out -> :waiting
      :else -> :done
    end
  end

  defp complete_sync(%__MODULE__{} = new_state) do
    sync_result =
      new_state.sources_by_key |> Stream.map(&elem(&1, 1)) |> Source.aggregate_results(new_state.inputs.full_last_batch)

    for from <- new_state.waiting_callers, do: GenServer.reply(from, sync_result)
    {:stop, :normal, new_state}
  end

  defp via(key), do: {:via, Registry, {@registry, key}}
end
