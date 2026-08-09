defmodule RadioBeam.EventHandler do
  @moduledoc """
  Behaviour for handling room events.

  Implemeters need to be added to the hard-coded set of queues in `config.exs`

  Also see `c:handle_pdu/2` for details on requirements of implementers and
  characteristics of the events that are to be handled.
  """
  alias RadioBeam.Database
  alias RadioBeam.Room.PDU
  alias RadioBeam.EventHandler.Server

  @type event_number() :: integer()
  @type queue() ::
          module()
          | {module(), term()}
          | {module(), term(), term()}
          | {module(), term(), term(), term()}
          | {module(), term(), term(), term(), term()}

  @doc """
  This callback function is invoked at least once for each PDU that has been
  persisted to a room DAG.

  This callback is invoked with PDUs in the same order that the PDUs were
  written to the room DAG. In Matrix Specification terms, that means they are
  processed in ["stream
  order"](https://matrix-org.github.io/synapse/v1.98/development/room-dag-concepts.html#depth-and-stream-ordering).
  However, PDUs contain a `prev_event_ids` field, which allow event handlers to
  build their own topological view of the DAG, if needed.

  The event handling system has at-least-once semantics. That is, an individual
  PDU can be assumed to be given to `handle_pdu/2` at least once. Therefore,
  implementers should be prepared to deduplicate as a part of their logic.

  # Queues Define Seriality

  By default, PDUs are routed to worker processes as defined by the
  `queues_for/1` function in this module. As such, be sure to update the
  relevant `config.exs` entries when writing a new event handler. The queues to
  route the PDU to can be overridden by providing `:queues` option via
  `queue_event/2`.

  Queues are almost always a tuple, where the first element is the callback
  module. The subsequent values of the queue-tuple constitute arbitrary terms
  that are used to uniquely identify the queue. **You must assume that the same
  event handler can be called concurrently for each distinct queue entry.**

  For example, if an event handler should be invoked serially
  per room, but concurrently across rooms, the queue entry should be
  `{HandlerMod, pdu.event.room_id}`. If it should be invoked serially per
  *user*, such as the sender of the event, the entry should be `{HandlerMod,
  pdu.event.sender}`. If the event handler must process every PDU globally
  (which, warning you now, for busy homeservers, could become an extreme
  bottleneck!), the entry should be just `HandlerMod` - note this is not
  wrapped in a tuple at all.
  """
  @callback handle_pdu(PDU.t(), get_state_at_pdu :: function()) :: :ok | {:error, :retry | :discard}

  @doc """
  A server admin, or the event processing system, is indicating to the event
  handler should reset its state (if any) to the given `t:event_number()`. This
  can happen in an attempt to recover the system if something goes wrong
  internally (queue database corruption, botched handler update).

  If the handler is able to oblige the request, it should perform whatever
  housekeeping it deems necessary in this situation (such as resetting or
  discarding state), and then return `{:ok, event_number}`, where
  `event_number` is the ***same event_number given to the function.*** The
  system will then re-apply PDUs from that point on until the handler catches
  up to the current-day state.

  If the handler cannot oblige the reset request, it must return `{:error,
  instruction}` with one of the following instructions:

  - `:from_the_top` - the handler cannot safely reset to the given
  `event_number`, but it can safely start from the beginning of the PDU stream.
  - `:continue` - the handler cannot safely reset to the given
  `event_number`, but it is safe to continue processing new events anyway,
  **even if some events are missed**. This option is mostly only used for
  handlers that do some kind of ephemeral work, like execute telemetry,
  broadcast PubSub messages, or send email alerts for specific events.
  - `:fatal` - the handler cannot safely reset to the given `event_number` and
  must not continue. The only potential path to recovery is manual
  intervention.
  """
  @callback reset_to(event_number()) :: {:ok, event_number()} | {:error, :from_the_top | :continue | :fatal}

  def queue_event(%PDU{} = pdu), do: queue_event(pdu, queues: queues_for(pdu))

  def queue_event(%PDU{} = pdu, opts) do
    queues = Keyword.get_lazy(opts, :queues, fn -> queues_for(pdu) end)
    notify? = Keyword.get(opts, :notify?, true)

    Enum.find_value(queues, :ok, fn queue ->
      with :ok <- Database.queue_event(queue, pdu.stream_number, pdu) do
        if notify?, do: Server.notify_event_queued(queue)
        _continue_to_next_queue = nil
      end
    end)
  end

  @room_id_keyed_handlers Application.compile_env!(:radio_beam, [__MODULE__, :room_id_keyed_handlers])
  @state_key_keyed_handlers Application.compile_env!(:radio_beam, [__MODULE__, :state_key_keyed_handlers])

  @spec queues_for(PDU.t()) :: [queue()]
  defp queues_for(%PDU{event: %{room_id: room_id, state_key: state_key}}) do
    Enum.concat([
      for(handler <- @room_id_keyed_handlers, do: {handler, room_id}),
      for(handler <- @state_key_keyed_handlers, do: {handler, state_key})
    ])
  end
end
