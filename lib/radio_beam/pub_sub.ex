defmodule RadioBeam.PubSub do
  @moduledoc """
  Helper functions for PubSub ops
  """

  def all_room_events(room_id), do: "events:#{room_id}"
end
