defmodule RadioBeam.Room.Threads do
  @moduledoc """
  Tracks m.thread root events in a room via `content.m.relates_to`
  """
  @behaviour RadioBeam.EventHandler

  alias RadioBeam.Room.Database
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.UserTimeline
  alias RadioBeam.Room.UserTimeline.Event

  def get_thread_event_ids(room_id, user_id, include, limit, from) when is_integer(limit) and limit in 0..50 do
    event_ids = Database.get_room_thread_parents(room_id, from: from, limit: limit)

    room_id
    |> UserTimeline.map_filter_user_events(user_id, event_ids)
    |> Stream.map(&Event.to_map/1)
    |> filter_by_include(include)
    |> Enum.uniq()
  end

  defp filter_by_include(event_maps, :all), do: event_maps

  defp filter_by_include(event_maps, :participated) do
    Stream.filter(event_maps, &get_in(&1, [:unsigned, "m.relations", "m.thread", :current_user_participated]))
  end

  @impl RadioBeam.EventHandler
  def handle_pdu(%PDU{} = pdu) do
    case pdu.event.content do
      %{"m.relates_to" => %{"rel_type" => "m.thread", "event_id" => thread_root_id}} ->
        Database.upsert_room_thread_parent(pdu.event.room_id, pdu.stream_number, thread_root_id)

      _else ->
        :ok
    end
  end

  @impl RadioBeam.EventHandler
  # handle_pdu is idempotent
  def reset_to(event_number), do: {:ok, event_number}
end
