defmodule RadioBeam.Room.View.Core.UserNotificationEventDispatcher do
  @moduledoc """
  View responsible for dispatching new events to room members'
  NotificationPusherServer.

  The server will only forward events to "join"ed room members, and it will
  forward regardless of whether the user has registered a pusher on one of
  their devices (clients can read outstanding notifications via
  /notifications).
  """

  alias RadioBeam.Room.PDU

  defstruct []

  def new!(), do: %__MODULE__{}

  def key_for(room_id, %PDU{}), do: {:ok, {__MODULE__, room_id}}

  def handle_pdu(%__MODULE__{}, room_id, _get_state_mapping, %PDU{event: event}) do
    # TODO: do not want to be calling into RadioBeam.User API from here.
    # Promote View concept to top-level?
    # it's also not desirable to make an OTP call like this from a Core module...
    RadioBeam.User.Notifications.handle_event(room_id, event.id, event.sender)
    %__MODULE__{}
  end
end
