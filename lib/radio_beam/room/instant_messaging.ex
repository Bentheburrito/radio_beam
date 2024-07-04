defmodule RadioBeam.Room.InstantMessaging do
  @moduledoc """
  Helper functions for sending human-readable messages to a room
  """

  @valid_msgtypes Enum.map(~w"text emote notice image file audio location video", &"m.#{&1}")
  defguard is_valid_msgtype(msgtype) when msgtype in @valid_msgtypes
end
