defmodule RadioBeam.Room.Core do
  @moduledoc """
  Functional core for the %Room{} aggregate/state machine.
  """
  import Kernel, except: [send: 2]

  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Core.Redactions
  alias RadioBeam.Room.Core.Relationships
  alias RadioBeam.Room.DAG
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.State

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

  @spec new(String.t(), User.id(), [create_opt()]) :: {Room.t(), :queue.queue(PDU.t())} | {:error, :unauthorized}
  def new(version, creator_id, deps, opts \\ []) do
    state = State.new!()

    create_event_attrs =
      Room.generate_id() |> to_string() |> Events.create(creator_id, version, Keyword.get(opts, :content, %{}))

    with {:ok, %AuthorizedEvent{} = create_event} <- State.authorize_event(state, create_event_attrs) do
      %DAG{} = dag = DAG.new!(create_event)
      %PDU{event: ^create_event} = create_pdu = DAG.fetch!(dag, create_event.id)
      state = State.handle_pdu(state, create_pdu)

      room = %Room{
        id: create_event.room_id,
        dag: dag,
        state: state,
        redactions: Redactions.new!(),
        relationships: Relationships.new!()
      }

      init_acc = {room, :queue.from_list([create_pdu])}

      create_event
      |> Events.initial_state_stream(opts)
      |> Enum.reduce_while(init_acc, fn event_attrs, {%Room{} = room, pdu_queue} ->
        case send(room, event_attrs, deps) do
          {:sent, %Room{} = room, pdu} -> {:cont, {room, :queue.in(pdu, pdu_queue)}}
          {:error, _error} = error -> {:halt, error}
        end
      end)
    end
  end

  def send(%Room{} = room, %AuthorizedEvent{type: "m.room.redaction"} = event, _deps) do
    room
    |> Redactions.apply_or_queue(event)
    |> send_common(event)
  end

  def send(%Room{id: room_id} = room, %AuthorizedEvent{type: "m.room.canonical_alias"} = event, deps) do
    [event.content["alias"] | Map.get(event.content, "alt_aliases", [])]
    |> Stream.filter(&is_binary/1)
    |> Enum.find_value(send_common(room, event), fn alias ->
      case deps.resolve_room_alias.(alias) do
        {:ok, ^room_id} -> false
        {:ok, _different_room_id} -> {:error, :alias_room_id_mismatch}
        {:error, _} = error -> error
      end
    end)
  end

  def send(%Room{} = room, %AuthorizedEvent{} = event, _deps), do: send_common(room, event)

  def send(%Room{} = room, event_attrs, deps) do
    event_attrs = Map.put(event_attrs, "prev_events", DAG.forward_extremities(room.dag))
    with {:ok, event} <- State.authorize_event(room.state, event_attrs), do: send(room, event, deps)
  end

  defp send_common(%Room{} = room, %AuthorizedEvent{} = event) do
    with %Room{} = room <- Relationships.apply_event(room, event) do
      {%DAG{} = dag, pdu} = DAG.append!(room.dag, event)

      room
      |> struct!(dag: dag, state: State.handle_pdu(room.state, pdu))
      |> Redactions.apply_any_pending(event.id)
      |> sent(pdu)
    end
  end

  defp sent(room, pdu), do: {:sent, room, pdu}
end
