defmodule RadioBeam.EventHandler.Server do
  @moduledoc """
  The `GenServer` that manages processing events on a particular
  `t:RadioBeam.EventHandler.queue`.
  """
  use GenServer, restart: :transient

  alias RadioBeam.Database
  alias RadioBeam.EventHandler.Server.Supervisor
  alias RadioBeam.EventHandler.State

  require Logger

  @registry RadioBeam.EventHandlerQueueRegistry
  @idle_timeout :timer.minutes(5)
  @retry_max_ms Application.compile_env!(:radio_beam, [RadioBeam.EventHandler.Server, :max_retry_timeout_ms])

  def registry, do: @registry

  def start_link(queue), do: GenServer.start_link(__MODULE__, queue, name: via(queue))

  def notify_event_queued(queue), do: cast(queue, :event_available)

  defp cast(queue, message) do
    case Registry.lookup(@registry, queue) do
      [{pid, _}] ->
        GenServer.cast(pid, message)

      _ ->
        Logger.debug("#{inspect(__MODULE__)} for #{inspect(queue)} is not alive, trying to start...")

        case State.validate_queue(queue) do
          :ok ->
            case Supervisor.start_handler(queue) do
              {:ok, pid} -> GenServer.cast(pid, message)
              {:error, {:already_started, pid}} -> GenServer.cast(pid, message)
              error -> cast_error(queue, error)
            end

          {:error, :invalid_queue} ->
            Logger.warning("#{inspect(__MODULE__)} got invalid queue #{inspect(queue)}")
        end
    end
  end

  defp cast_error(queue, {:error, error}) do
    Logger.error("Error reviving #{inspect(queue)}: #{inspect(error)}")
    {:error, error}
  end

  ### IMPL ###

  @impl GenServer
  def init(queue), do: {:ok, queue, {:continue, :init}}

  @impl GenServer
  def handle_continue(:init, queue) do
    Logger.debug("Attempting to start event handler #{inspect(queue)} server")

    case Database.fetch_event_handler_state(queue) do
      {:ok, %State{} = handler_state} -> {:noreply, handler_state}
      {:error, :not_found} -> process_init(queue)
      {:error, error} -> {:error, error}
    end
  end

  @impl GenServer
  def handle_continue(:process_event, %State{} = handler_state) do
    case State.disposition(handler_state) do
      :good ->
        case State.process(handler_state) do
          # everything going smoothly - tight loop to continue processing
          {:ok, %State{} = handler_state} -> {:noreply, handler_state, {:continue, :process_event}}
          # first failed event processed - next recursion will decide what to do
          {:error, %State{} = handler_state} -> schedule_retry(handler_state)
          # no work left on the queue for now, spin down if nothing new after a while
          :done -> {:noreply, handler_state, @idle_timeout}
        end

      {:failing, attempts} ->
        Logger.warning("#{log_prelude(handler_state)}: trying to process event after failing #{attempts} times")

        case State.process(handler_state) do
          # handler seems to have recovered, continue processing
          {:ok, %State{} = handler_state} -> log_recovery(handler_state)
          # not looking good, let's back off if it's failing
          {:error, %State{} = handler_state} -> schedule_retry(handler_state)
          # kind of a weird state - we're failing but nothing to do? just wait for more I guess
          :done -> {:noreply, handler_state, @idle_timeout}
        end
    end
  end

  @impl GenServer
  def handle_cast(:event_available, %State{} = handler_state) do
    case State.disposition(handler_state) do
      :good -> {:noreply, handler_state, {:continue, :process_event}}
      # do not idle timeout when failing - there should have a retry timer active
      {:failing, _attempts} -> {:noreply, handler_state}
    end
  end

  @impl GenServer
  def handle_info(:retry, %State{} = handler_state), do: {:noreply, handler_state, {:continue, :process_event}}
  def handle_info(:timeout, %State{} = handler_state), do: {:stop, :normal, handler_state}

  defp process_init(queue) do
    Logger.debug("Starting event handler queue for the first time #{inspect(queue)}")

    case State.process_init(queue) do
      {:ok, %State{} = handler_state} -> {:noreply, handler_state, {:continue, :process_event}}
      {:error, %State{} = handler_state} -> {:noreply, handler_state, {:continue, :process_event}}
      :done -> {:stop, :normal, queue}
    end
  end

  defp schedule_retry(handler_state) do
    {:failing, attempts} = State.disposition(handler_state)
    retry_ms = (attempts * 2) |> :timer.seconds() |> min(@retry_max_ms)
    Logger.error("#{log_prelude(handler_state)}: failed #{attempts} times, retrying in #{retry_ms}ms")
    Process.send_after(self(), :retry, retry_ms)
    {:noreply, handler_state}
  end

  defp log_prelude(handler_state), do: "#{inspect(__MODULE__)} (queue #{inspect(State.queue(handler_state))})"

  defp log_recovery(handler_state) do
    Logger.warning("#{log_prelude(handler_state)} has recovered!")
    {:noreply, handler_state, {:continue, :process_event}}
  end

  defp via(queue), do: {:via, Registry, {@registry, queue}}
end
