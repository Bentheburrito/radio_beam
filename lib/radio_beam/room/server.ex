defmodule RadioBeam.Room.Server do
  @moduledoc """
  The GenServer that uses Room.Impl to drive changes in a room.
  """
  use GenServer

  alias Phoenix.PubSub
  alias RadioBeam.PubSub, as: PS
  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.RoomSupervisor
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache

  require Logger

  def start_link({room_id, _events_or_room} = init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: via(room_id))
  end

  def call(room_id, message) do
    case Registry.lookup(RadioBeam.RoomRegistry, room_id) do
      [{pid, _}] ->
        GenServer.call(pid, message)

      _ ->
        Logger.debug("Room.Server is not alive, trying to start...")

        case Room.get(room_id) do
          {:ok, %Room{} = room} ->
            case DynamicSupervisor.start_child(RoomSupervisor, {__MODULE__, {room.id, room}}) do
              {:ok, pid} -> GenServer.call(pid, message)
              error -> error
            end

          {:error, :not_found} ->
            {:error, :room_does_not_exist}

          {:error, error} ->
            Logger.error("Error reviving #{room_id}: #{inspect(error)}")
            {:error, error}
        end
    end
  end

  ### IMPL ###

  @impl GenServer
  def init({room_id, events_or_room}) do
    case events_or_room do
      [%{"type" => "m.room.create", "content" => %{"room_version" => version}} | _] = events ->
        init_room = %Room{id: room_id, latest_event_ids: [], state: %{}, version: version}

        case Room.Impl.put_events(init_room, events) do
          {:ok, %Room{} = room, _pdus} -> {:ok, room}
          {:error, :unauthorized} -> {:stop, :invalid_state}
          {:error, %Ecto.Changeset{} = changeset} -> {:stop, inspect(changeset.errors)}
          {:error, :alias_in_use} -> {:stop, :alias_in_use}
          {:error, _txn_fxn_name, error} -> {:stop, error}
          {:error, error} -> {:stop, inspect(error)}
        end

      %Room{} = room ->
        {:ok, room}

      invalid_init_arg ->
        reason = "Tried to start a Room with invalid arg: #{inspect(invalid_init_arg)}"
        Logger.error("Aborting room #{room_id} GenServer init: #{reason}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:put_event, event}, _from, %Room{} = room) do
    case Room.Impl.put_event(room, event) do
      {:ok, room, [pdu]} ->
        PubSub.broadcast(PS, PS.all_room_events(room.id), {:room_event, room.id, pdu})

        if pdu.type in Room.stripped_state_types(),
          do: PubSub.broadcast(PS, PS.stripped_state_events(room.id), {:room_stripped_state, room.id, pdu})

        if pdu.type == "m.room.member" do
          if pdu.content["membership"] == "invite" do
            PubSub.broadcast(PS, PS.invite_events(pdu.state_key), {:room_invite, room, pdu})
          end

          LazyLoadMembersCache.mark_dirty(room.id, pdu.state_key)
        end

        {:reply, {:ok, pdu.event_id}, room}

      {:error, :duplicate_annotation} = e ->
        {:reply, e, room}

      {:error, :unauthorized} = e ->
        Logger.info("rejecting an event for being unauthorized: #{inspect(event)}")
        {:reply, e, room}

      {:error, error} ->
        Logger.error("""
        An error occurred trying to put an event: #{inspect(error)}
        ∟> The event: #{inspect(event)}
        """)

        {:reply, {:error, :internal}, room}
    end
  end

  @impl GenServer
  def handle_call({:try_redact, %PDU{} = to_redact, %PDU{type: "m.room.redaction"} = pdu}, _from, %Room{} = room) do
    {:reply, Room.Impl.try_redact(room, to_redact, pdu), room}
  end

  defp via(room_id), do: {:via, Registry, {RadioBeam.RoomRegistry, room_id}}
end
