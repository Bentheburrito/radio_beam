defmodule RadioBeam.Room.View.Core.Threads do
  @moduledoc """
  Tracks m.thread root events in a room via `content.m.relates_to`
  """
  defstruct event_ids: :gb_sets.new()

  @opaque t() :: %__MODULE__{}

  alias RadioBeam.Room.PDU

  def new!, do: %__MODULE__{}

  def key_for(room_id, _pdu), do: {:ok, {__MODULE__, room_id}}

  def handle_pdu(%__MODULE__{} = thread_roots, _room_id, _state_mapping, %PDU{} = pdu) do
    event_ids =
      case pdu.event.content do
        %{"m.relates_to" => %{"rel_type" => "m.thread", "event_id" => thread_root_id}} ->
          :gb_sets.add({pdu.stream_number, thread_root_id}, thread_roots.event_ids)

        _else ->
          thread_roots.event_ids
      end

    struct!(thread_roots, event_ids: event_ids)
  end

  def stream_event_ids(%__MODULE__{event_ids: event_ids}) do
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
end
