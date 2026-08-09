defmodule RadioBeam.EventHandler.State do
  @moduledoc """
  This module contains the logic of an EventHandler and its internal state.
  """
  alias RadioBeam.Database
  alias RadioBeam.PubSub
  alias RadioBeam.Room.PDU

  @attrs ~w|queue callback_mod latest_processed_event_number disposition|a
  @enforce_keys @attrs
  defstruct @attrs
  @opaque t() :: %__MODULE__{}

  @type disposition() :: :good | {:failing, failed_attempts :: non_neg_integer()}

  def process_init(queue) do
    callback_mod = if is_atom(queue), do: queue, else: elem(queue, 0)

    with {:ok, event_number, %PDU{stream_number: event_number} = pdu} <- Database.peek_event(queue),
         {:ok, %__MODULE__{} = state} <- handle_pdu(new!(queue, callback_mod, event_number), pdu) do
      mark_event_processed(state, event_number, pdu.event.id)
    end
  end

  defp handle_pdu(%__MODULE__{} = state, pdu) do
    # TODO
    get_state_at_pdu = fn -> %{} end

    case state.callback_mod.handle_pdu(pdu, get_state_at_pdu) do
      :ok -> {:ok, put_in(state.disposition, :good)}
      {:error, :retry} -> {:error, put_failing_disposition(state)}
    end
  end

  defp put_failing_disposition(%__MODULE__{} = state) do
    update_in(
      state.disposition,
      fn
        :good -> {:failing, 1}
        {:failing, attempts} -> {:failing, attempts + 1}
      end
    )
  end

  defp new!(queue, callback_mod, latest_event_num) do
    %__MODULE__{
      queue: queue,
      callback_mod: callback_mod,
      latest_processed_event_number: latest_event_num,
      disposition: :good
    }
  end

  defp mark_event_processed(state, event_number, event_id) do
    state = put_in(state.latest_processed_event_number, event_number)

    with :ok <- Database.mark_event_processed(state.queue, state, event_number) do
      PubSub.broadcast(
        PubSub.read_model_caught_up_to(state.queue),
        {:read_model_caught_up_to, state.queue, event_number, event_id}
      )

      {:ok, state}
    end
  end

  def process(%__MODULE__{} = state) do
    with {:ok, event_number, %PDU{stream_number: event_number} = pdu} <- Database.peek_event(state.queue),
         {:ok, state} <- handle_pdu(state, pdu) do
      mark_event_processed(state, event_number, pdu.event.id)
    end
  end

  def validate_queue({}), do: {:error, :invalid_queue}
  def validate_queue(queue_tuple) when is_tuple(queue_tuple), do: queue_tuple |> elem(0) |> validate_queue()

  def validate_queue(module) when is_atom(module) do
    if function_exported?(module, :handle_pdu, 2) and function_exported?(module, :reset_to, 1),
      do: :ok,
      else: {:error, :invalid_queue}
  end

  def validate_queue(_not_valid), do: {:error, :invalid_queue}

  def disposition(%__MODULE__{disposition: disposition}), do: disposition
  def queue(%__MODULE__{queue: queue}), do: queue
end
