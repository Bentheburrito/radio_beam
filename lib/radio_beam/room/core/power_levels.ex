defmodule RadioBeam.Room.Core.PowerLevels do
  @moduledoc """
  Permission checks for room members.
  """
  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.Room.Chronicle

  def user_has_power?(room_version, state_mapping, power_level_content_path, user_id, state_event?) do
    RoomVersion.has_power?(room_version, user_id, power_level_content_path, state_event?, state_mapping)
  end

  def can_send_event?(room, user_id, event_type, state_key \\ :none) do
    room_version = Chronicle.room_version(room.chronicle)
    state_mapping = Chronicle.get_state_event_mapping(room.chronicle, :current_state, true)
    state_event? = state_key != :none

    user_has_power?(room_version, state_mapping, ["events", event_type], user_id, state_event?)
  end
end
