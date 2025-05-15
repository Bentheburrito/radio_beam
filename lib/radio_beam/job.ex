defmodule RadioBeam.Job do
  @moduledoc """
  An extremely simple job processor, backed by mnesia.
  """
  use GenServer

  use Memento.Table,
    attributes: [:key, :mfa, :attempt, :max_attempts, :on_failure],
    type: :ordered_set

  alias RadioBeam.Repo
  alias RadioBeam.Job.Processor

  require Logger

  @not_attempted 0

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  def insert(worker, m, f, a, opts \\ []) do
    schedule_for = opts |> Keyword.get(:schedule_for, DateTime.utc_now()) |> DateTime.to_unix(:millisecond)
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    job = %__MODULE__{
      key: {worker, schedule_for, Ecto.UUID.generate()},
      mfa: {m, f, a},
      attempt: @not_attempted,
      max_attempts: max_attempts,
      on_failure: Keyword.get(opts, :on_failure)
    }

    Repo.insert!(job)

    send_run_job_message(Processor.worker_name(worker), job.key)
    :ok
  end

  defp send_run_job_message(to \\ self(), {_worker, run_at, _id} = key) do
    Process.send_after(to, {:run_job, key}, max(0, run_at - :os.system_time(:millisecond)))
  end

  ### IMPL ###

  @impl GenServer
  def init(worker) do
    Enum.each(all_pending(worker), &send_run_job_message(&1.key))
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:run_job, key}, state) do
    {:noreply, start_job(key, state)}
  end

  # The task completed successfully
  @impl GenServer
  def handle_info({ref, result}, state) when is_map_key(state, ref) do
    {:noreply, handle_job_result(ref, result, state)}
  end

  # If the task fails
  @impl GenServer
  def handle_info({:DOWN, ref, _, _, reason}, state) when is_map_key(state, ref) do
    {:noreply, handle_job_failure(ref, reason, state)}
  end

  defp start_job({worker, _, _} = key, state) do
    %{mfa: {m, f, a}} = get(key)

    task =
      try do
        Task.Supervisor.async_nolink(Processor.worker_task_sup(worker), m, f, a)
      rescue
        RuntimeError -> :max_concurrency_reached
      end

    if task == :max_concurrency_reached do
      Map.update(state, :ready, [key], &[key | &1])
    else
      Map.put(state, task.ref, key)
    end
  end

  defp handle_job_result(ref, result, state) do
    case result do
      :error -> handle_job_failure(ref, "Task MFA returned :error", state)
      {:error, error} -> handle_job_failure(ref, "Task MFA returned {:error, #{inspect(error)}}", state)
      _success -> handle_job_success(ref, state)
    end
  end

  defp handle_job_success(ref, state) do
    # We don't care about the DOWN message now, so let's demonitor and flush it
    Process.demonitor(ref, [:flush])

    state =
      case Map.get(state, :ready) do
        [key | rest_ready] -> start_job(key, Map.put(state, :ready, rest_ready))
        _else -> state
      end

    {key, state} = Map.pop!(state, ref)
    delete(key)

    state
  end

  defp handle_job_failure(ref, reason, state) do
    {key, state} = Map.pop!(state, ref)
    job = get(key)
    current_attempt = job.attempt + 1

    state =
      if current_attempt >= job.max_attempts do
        delete(job.key)

        Logger.error("""
        A job #{inspect(job.key)} with MFA #{inspect(job.mfa)} failed during its final attempt with reason: #{inspect(reason)}
        """)

        state
      else
        now = :os.system_time(:millisecond)
        retry_in = next_backoff(current_attempt)

        reschedule(job, now + retry_in)

        Logger.warning("""
        A job #{inspect(job.key)} (#{current_attempt}/#{job.max_attempts}) with MFA #{inspect(job.mfa)} failed with reason #{inspect(reason)}
        Retrying in #{retry_in}
        """)

        state
      end

    if is_function(job.on_failure, 4) do
      Task.start(fn -> job.on_failure.(key, reason, current_attempt, job.max_attempts) end)
    end

    state
  end

  defp all_pending(worker) do
    match_head = __MODULE__.__info__().query_base
    match_spec = [{put_elem(match_head, 1, {worker, :_, :_}), [], [:"$_"]}]
    Repo.transaction!(fn -> Memento.Query.select_raw(__MODULE__, match_spec) end)
  end

  defp get(key) do
    {:ok, job} = Repo.fetch(__MODULE__, key)
    job
  end

  defp reschedule(job, at) do
    {worker, _old_schedule_at, id} = job.key

    %{key: new_key} =
      Repo.transaction!(fn ->
        Repo.delete(job)
        Repo.insert!(%__MODULE__{job | key: {worker, at, id}, attempt: job.attempt + 1})
      end)

    send_run_job_message(Processor.worker_name(worker), new_key)
  end

  defp delete(key) do
    Logger.info("Job completed successfully, deleting: #{inspect(key)}")
    Repo.delete(__MODULE__, key)
  end

  defp next_backoff(attempt), do: :timer.seconds(2 ** attempt)
end
