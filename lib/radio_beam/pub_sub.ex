defmodule RadioBeam.PubSub do
  @moduledoc """
  Helper functions for PubSub ops
  """
  alias Phoenix.PubSub
  alias RadioBeam.ContentRepo.MatrixContentURI

  def subscribe(topic), do: PubSub.subscribe(__MODULE__, topic)
  def broadcast(topic, message), do: PubSub.broadcast(__MODULE__, topic, message)

  ## TOPICS ##

  def all_room_events(room_id), do: "events:#{room_id}"
  def invite_events(user_id), do: "invite:#{user_id}"

  def file_uploaded(%MatrixContentURI{} = mxc), do: "file_uploaded:#{mxc}"
end
