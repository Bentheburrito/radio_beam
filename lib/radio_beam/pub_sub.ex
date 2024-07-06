defmodule RadioBeam.PubSub do
  def all_room_events(room_id), do: "events:#{room_id}"
end
