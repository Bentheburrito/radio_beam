defmodule RadioBeam.Database do
  @moduledoc """
  A behaviour for implementing a persistence backend. RadioBeam includes the
  `RadioBeam.Database.Mnesia` backend out of the box.

  The backend must support executing multiple database operations in the
  context of a transaction. This is accomplished via the `c:transaction/1`
  callback, whose argument is a 0-arity function which contains database writes
  that should be considered one atomic action.
  """

  alias RadioBeam.EventHandler

  @callback init() :: :ok | {:error, String.t()}
  @callback queue_event(EventHandler.queue(), EventHandler.event_number(), term(), PDU.t()) :: :ok
  @callback peek_event(EventHandler.queue()) :: {:ok, EventHandler.event_number(), PDU.t()}
  @callback mark_event_processed(EventHandler.queue(), EventHandler.State.t(), EventHandler.event_number(), term()) ::
              :ok
  @callback fetch_event_handler_state(EventHandler.queue()) :: {:ok, EventHandler.State.t()} | {:error, :not_found}

  @database_backend Application.compile_env!(:radio_beam, [RadioBeam.Database, :backend])

  defdelegate init, to: @database_backend
  defdelegate queue_event(queue, event_number, event_id, event), to: @database_backend
  defdelegate peek_event(queue), to: @database_backend
  defdelegate mark_event_processed(queue, state, event_number, event_id), to: @database_backend
  defdelegate fetch_event_handler_state(queue), to: @database_backend
end
