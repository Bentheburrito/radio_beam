defmodule RadioBeam.Room.Core do
  @moduledoc """
  Functional core for the %Room{} aggregate/state machine.
  """
  import Kernel, except: [send: 2]

  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Chronicle
  alias RadioBeam.Room.Core.Redactions
  alias RadioBeam.Room.Core.Relationships
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.PDU

  @typedoc """
  Options to configure a new room with.

  TODO: document overview of each variant here
  """
  @type create_opt() ::
          {:power_levels, map()}
          | {:preset, :private_chat | :trusted_private_chat | :public_chat}
          | {:addl_state_events, [map()]}
          | {:alias | :name | :topic, String.t()}
          | {:content, map()}
          | {:invite | :invite_3pid, [String.t()]}
          | {:direct?, boolean()}
          | {:visibility, :public | :private}

  ### CREATE / WRITE ###

  @spec new(String.t(), User.id(), deps :: map(), [create_opt()]) ::
          {Room.t(), :queue.queue(PDU.t())} | {:error, :unauthorized}
  def new(version, creator_id, deps, opts \\ []) do
    chronicle_backend = Keyword.get(opts, :chronicle_backend, Chronicle.Map)
    dag_backend = Keyword.get(opts, :dag_backend, RadioBeam.DAG.Map)

    chronicle =
      (&Room.generate_legacy_id/0)
      |> Events.create(creator_id, version, Keyword.get(opts, :content, %{}))
      |> chronicle_backend.new!(dag_backend)

    create_event = Chronicle.get_create_event(chronicle)

    room = %Room{
      id: Chronicle.room_id(chronicle),
      chronicle: chronicle,
      redactions: Redactions.new!(),
      relationships: Relationships.new!()
    }

    init_acc = {room, :queue.from_list([Chronicle.fetch_pdu!(chronicle, create_event.id)])}

    create_event
    |> Events.initial_state_stream(opts)
    |> Enum.reduce_while(init_acc, fn event_attrs, {%Room{} = room, pdu_queue} ->
      case send(room, event_attrs, deps) do
        {:sent, %Room{} = room, _event_id, [pdu]} ->
          {:cont, {room, :queue.in(pdu, pdu_queue)}}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
  end

  def send(%Room{} = room, %AuthorizedEvent{type: "m.room.redaction"} = event, _deps) do
    case Redactions.apply_or_queue(room, event) do
      {:queued, room} -> {:sent, room, event.id, []}
      {:applied, room, ^event} -> send_common(room, event)
      {:not_applied, room} -> {:sent, room, event.id, []}
    end
  end

  def send(%Room{id: room_id} = room, %AuthorizedEvent{type: "m.room.canonical_alias"} = event, deps) do
    [event.content["alias"] | Map.get(event.content, "alt_aliases", [])]
    |> Stream.filter(&is_binary/1)
    # TODO: if one alias reg fails, we should unregister any previous that succeeded
    |> Enum.find_value(send_common(room, event), fn alias ->
      with {:ok, alias} <- Room.Alias.new(alias),
           :ok <- deps.register_room_alias.(alias, room_id) do
        false
      end
    end)
  end

  def send(%Room{} = room, %AuthorizedEvent{} = event, _deps), do: send_common(room, event)

  def send(%Room{} = room, event_attrs, deps) do
    with {:ok, chronicle, event} <- Chronicle.try_append(room.chronicle, event_attrs) do
      room.chronicle
      |> put_in(chronicle)
      |> send(event, deps)
    end
  end

  defp send_common(%Room{} = room, %AuthorizedEvent{} = event) do
    with %Room{} = room <- Relationships.apply_event(room, event) do
      event_pdu = Chronicle.fetch_pdu!(room.chronicle, event.id)

      case Redactions.apply_any_pending(room, event.id) do
        {:applied, room, redaction_event} ->
          %Room{} = room = Relationships.apply_event(room, redaction_event)
          sent(room, event.id, [event_pdu, Chronicle.fetch_pdu!(room.chronicle, redaction_event.id)])

        {:not_applied, room} ->
          sent(room, event.id, [event_pdu])
      end
    end
  end

  defp sent(room, event_id, pdus) when is_list(pdus), do: {:sent, room, event_id, pdus}

  def get_state_mapping(room), do: Chronicle.get_state_mapping(room.chronicle, :current_state, _apply_event_ids? = true)

  def get_state_mapping(room, type, state_key \\ "") do
    case get_state_mapping(room) do
      %{{^type, ^state_key} => event_id} -> {:ok, event_id}
      _else -> {:error, :not_found}
    end
  end

  def get_state_mapping_at(room, event_id, apply_event_ids? \\ true),
    do: Chronicle.get_state_mapping(room.chronicle, event_id, apply_event_ids?)

  def get_state_mapping_at(room, event_id, type, state_key, apply_event_ids? \\ true) do
    case get_state_mapping_at(room, event_id, apply_event_ids?) do
      %{{^type, ^state_key} => event_id} -> {:ok, event_id}
      _else -> {:error, :not_found}
    end
  end
end
