defmodule RadioBeam.Room.Core.PowerLevels do
  @moduledoc """
  Permission checks for room members.
  """
  alias Polyjuice.Util.RoomVersion

  def user_has_power?(room_version, state_mapping, power_level_content_path, user_id, state_event?) do
    RoomVersion.has_power?(room_version, user_id, power_level_content_path, state_event?, state_mapping)
  end
end
