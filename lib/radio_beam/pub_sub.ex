defmodule RadioBeam.PubSub do
  @moduledoc """
  Helper functions for PubSub ops
  """
  alias Phoenix.PubSub
  alias RadioBeam.ContentRepo.MatrixContentURI

  def subscribe(topic), do: PubSub.subscribe(__MODULE__, topic)
  def broadcast(topic, message), do: PubSub.broadcast(__MODULE__, topic, message)

  ## TOPICS ##

  def account_data_updated(user_id), do: "account_data_updated:#{user_id}"
  def all_room_events(room_id), do: "events:#{room_id}"
  def file_uploaded(%MatrixContentURI{} = mxc), do: "file_uploaded:#{mxc}"
  def invite_events(user_id), do: "invite:#{user_id}"
  def to_device_message_available(user_id, device_id), do: "device_msg_avail:#{user_id}:#{device_id}"
  def user_joined_room(user_id), do: "room_joined:#{user_id}"
  def user_membership_or_crypto_id_changed, do: "crypto_id_update"
end
