defmodule RadioBeam.Room.Server do
  @moduledoc """
  The `GenServer` that manages a particular Matrix Room.
  `RadioBeam.Room.Server`s should not be directly interacted with outside of
  the the public `RadioBeam.Room` API.
  """
  use GenServer

  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room.Server.Supervisor

  require Logger

  @do_not_log_errors ~w|duplicate_annotation|a

  def start_link(%Room{id: room_id} = room), do: GenServer.start_link(__MODULE__, room, name: via(room_id))

  def start_link({%Room{id: room_id} = room, pdu_queue}),
    do: GenServer.start_link(__MODULE__, {room, pdu_queue}, name: via(room_id))

  def create(version, creator_id, opts) do
    with {%Room{} = room, pdu_queue} <- Room.Core.new(version, creator_id, deps(), opts),
         %Room{} <- Repo.insert!(room),
         {:ok, _pid} <- Supervisor.start_room(room, pdu_queue) do
      {:ok, room.id}
    end
  end

  def send(room_id, event_attrs), do: call(room_id, {:send, event_attrs})

  def ping(room_id), do: call(room_id, :ping)

  defp call(room_id, message) do
    case Registry.lookup(RadioBeam.RoomRegistry, room_id) do
      [{pid, _}] ->
        GenServer.call(pid, message)

      _ ->
        Logger.debug("Room.Server for #{room_id} is not alive, trying to start...")

        case Repo.fetch(Repo.Tables.Room, room_id) do
          {:ok, %Room{} = room} ->
            with {:ok, pid} <- Supervisor.start_room(room), do: GenServer.call(pid, message)

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
  def init(%Room{} = room), do: {:ok, room}
  def init({%Room{} = room, pdu_queue}), do: {:ok, room, {:continue, pdu_queue}}

  @impl GenServer
  def handle_continue(pdu_queue, %Room{} = room) do
    pdu_stream =
      Stream.unfold(pdu_queue, fn pdu_queue ->
        case :queue.out(pdu_queue) do
          {{:value, %PDU{} = pdu}, pdu_queue} -> {pdu, pdu_queue}
          {:empty, ^pdu_queue} -> nil
        end
      end)

    for pdu <- pdu_stream, do: Room.View.handle_pdu(room, pdu)

    {:noreply, room}
  end

  @impl GenServer
  def handle_call({:send, event_attrs}, _from, %Room{} = room) do
    case Room.Core.send(room, event_attrs, deps()) do
      {:sent, %Room{} = room, %PDU{event: event} = pdu} ->
        Repo.insert!(room)

        Room.View.handle_pdu(room, pdu)

        if event.type == "m.room.member" and event.content["membership"] == "invite" do
          # note: `mark_dirty` needs to be called after Views are updated, not
          # just when write model is updated
          LazyLoadMembersCache.mark_dirty(room.id, event.state_key)
        end

        {:reply, {:ok, event.id}, room}

      {:error, :unauthorized} = e ->
        Logger.info("rejecting an event for being unauthorized: #{inspect(event_attrs)}")
        {:reply, e, room}

      {:error, error} = e when error in @do_not_log_errors ->
        {:reply, e, room}

      {:error, error} ->
        Logger.error("""
        An error occurred trying to send an event into room #{room.id}: #{inspect(error)}
        The event_attrs: #{inspect(event_attrs)}
        """)

        {:reply, {:error, :internal}, room}
    end
  end

  @impl GenServer
  def handle_call(:ping, _from, %Room{} = room), do: {:reply, :pong, room}

  defp deps do
    %{register_room_alias: fn alias, room_id -> with {:ok, _} <- Room.Alias.put(alias, room_id), do: :ok end}
  end

  defp via(room_id), do: {:via, Registry, {RadioBeam.RoomRegistry, room_id}}
end
