defmodule RadioBeam.Room.Server do
  @moduledoc """
  The `GenServer` that manages a particular Matrix Room.
  `RadioBeam.Room.Server`s should not be directly interacted with outside of
  the the public `RadioBeam.Room` API.
  """
  use GenServer

  alias RadioBeam.PubSub
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room.Server.Supervisor

  require Logger

  @do_not_log_errors ~w|duplicate_annotation|a

  def start_link(%Room{id: room_id} = room), do: GenServer.start_link(__MODULE__, room, name: via(room_id))

  def create(version, creator_id, opts) do
    with %Room{} = room <- Room.Core.new(version, creator_id, opts),
         {:ok, _pid} <- Supervisor.start_room(room) do
      {:ok, room.id}
    end
  end

  def send(room_id, event_attrs), do: call(room_id, {:send, event_attrs})

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

  @impl GenServer
  def handle_call({:send, event_attrs}, _from, %Room{} = room) do
    case Room.Core.send(room, event_attrs, deps()) do
      {:sent, %Room{} = room, %PDU{event: event} = pdu} ->
        Repo.insert!(room)

        Room.View.handle_pdu(room, pdu)

        # TODO: remove
        PubSub.broadcast(PubSub.all_room_events(room.id), {:room_event, event})

        if event.type == "m.room.member" do
          if event.content["membership"] == "invite" do
            PubSub.broadcast(PubSub.invite_events(event.state_key), {:room_invite, room.id})
          end

          LazyLoadMembersCache.mark_dirty(room.id, event.state_key)
        end

        {:reply, {:ok, pdu}, room}

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

  defp deps do
    %{resolve_room_alias: &Room.Alias.get_room_id/1}
  end

  defp via(room_id), do: {:via, Registry, {RadioBeam.RoomRegistry, room_id}}
end
