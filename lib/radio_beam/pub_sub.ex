defmodule RadioBeam.PubSub do
  @moduledoc """
  Helper functions for PubSub ops
  """
  alias RadioBeam.ContentRepo.MatrixContentURI

  def all_room_events(room_id), do: "events:#{room_id}"
  def stripped_state_events(room_id), do: "stripped_state:#{room_id}"
  def invite_events(user_id), do: "invite:#{user_id}"

  def file_available(%MatrixContentURI{} = mxc), do: "file_available:#{mxc}"
end
