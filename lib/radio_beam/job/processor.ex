defmodule RadioBeam.Job.Processor do
  use Supervisor

  alias RadioBeam.Job

  def start_link(opts) do
    workers = Keyword.fetch!(opts, :workers)
    Supervisor.start_link(__MODULE__, workers)
  end

  @impl Supervisor
  def init(workers) do
    children =
      Enum.flat_map(workers, fn
        {worker, concurrency} -> children(worker, concurrency)
        worker -> children(worker)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  def worker_name(worker), do: Module.concat(RadioBeam.Job.Worker, worker)
  def worker_task_sup(worker), do: Module.concat([worker_name(worker), TaskSupervisor])

  defp children(worker, concurrency \\ 10) do
    [
      # Start the workers/Task.Supervisors
      {Task.Supervisor, name: worker_task_sup(worker), max_children: concurrency},
      # Start the Job handler
      {Job, name: worker_name(worker)}
    ]
  end
end
