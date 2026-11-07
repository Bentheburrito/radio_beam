defmodule RadioBeam.Config do
  @moduledoc """
  Config-reading helpers
  """
  def server_name, do: fetch_env!(:server_name)
  def local_homeservers, do: fetch_env!(:local_homeservers)

  def admins(server_name),
    do: Enum.find(local_homeservers(), %{admins: []}, &(&1.server_display_name == server_name)).admins

  def supported_room_versions, do: fetch_env!(:capabilities)["m.room_versions"].available
  def default_room_version, do: fetch_env!(:capabilities)["m.room_versions"].default
  def max_timeline_events, do: get_env(:max_events)[:timeline]
  def max_state_events, do: get_env(:max_events)[:state]

  defp fetch_env!(key), do: Application.fetch_env!(:radio_beam, key)
  defp get_env(key), do: Application.get_env(:radio_beam, key)
end
