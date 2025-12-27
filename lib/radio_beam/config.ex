defmodule RadioBeam.Config do
  @moduledoc """
  Config-reading helpers
  """
  def server_name, do: Application.fetch_env!(:radio_beam, :server_name)
  def admins, do: Application.fetch_env!(:radio_beam, :admins)

  def supported_room_versions, do: Application.fetch_env!(:radio_beam, :capabilities)[:"m.room_versions"].available
  def default_room_version, do: Application.fetch_env!(:radio_beam, :capabilities)[:"m.room_versions"].default
  def max_timeline_events, do: Application.get_env(:radio_beam, :max_events)[:timeline]
  def max_state_events, do: Application.get_env(:radio_beam, :max_events)[:state]
end
