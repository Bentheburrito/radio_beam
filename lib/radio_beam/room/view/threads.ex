defmodule RadioBeam.Room.View.Threads do
  @moduledoc """
  Tracks m.thread root events in a room via `content.m.relates_to`
  """
  @behaviour RadioBeam.EventHandler

  defstruct event_ids: :gb_sets.new()

  @opaque t() :: %__MODULE__{}

  alias RadioBeam.Room.Database
  alias RadioBeam.Room.PDU

  def new!, do: %__MODULE__{}

  @doc "Returns a `Stream` of the parent thread IDs in a room"
  def stream_event_ids(room_id) do
    %__MODULE__{event_ids: event_ids} = fetch!(room_id)

    event_ids
    |> :gb_sets.iterator(:reversed)
    |> Stream.unfold(fn set_iter ->
      case :gb_sets.next(set_iter) do
        {{_stream_number, "$" <> _ = event_id}, set_iter} -> {event_id, set_iter}
        :none -> nil
      end
    end)
    |> Stream.uniq()
  end

  defp fetch!(room_id) do
    case Database.fetch_view(key(room_id)) do
      {:ok, %__MODULE__{} = threads} -> threads
      {:error, :not_found} -> new!()
    end
  end

  defp key(room_id), do: {__MODULE__, room_id}

  @impl RadioBeam.EventHandler
  def handle_pdu(%PDU{} = pdu, _) do
    %__MODULE__{} = thread_roots = fetch!(pdu.event.room_id)

    event_ids =
      case pdu.event.content do
        %{"m.relates_to" => %{"rel_type" => "m.thread", "event_id" => thread_root_id}} ->
          :gb_sets.add({pdu.stream_number, thread_root_id}, thread_roots.event_ids)

        _else ->
          thread_roots.event_ids
      end

    thread_roots = struct!(thread_roots, event_ids: event_ids)
    Database.upsert_view(key(pdu.event.room_id), thread_roots)
  end

  @impl RadioBeam.EventHandler
  # handle_pdu is idempotent
  def reset_to(event_number), do: {:ok, event_number}
end
