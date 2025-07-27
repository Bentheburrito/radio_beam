defmodule RadioBeam do
  @moduledoc """
  RadioBeam keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  def server_name, do: Application.fetch_env!(:radio_beam, :server_name)

  def admins, do: Application.fetch_env!(:radio_beam, :admins)

  def env, do: Application.fetch_env!(:radio_beam, :env)

  def default_room_version, do: Application.fetch_env!(:radio_beam, :capabilities)[:"m.room_versions"].default

  @cs_event_keys ["content", "event_id", "origin_server_ts", "room_id", "sender", "state_key", "type", "unsigned"]
  @doc """
  Strips an event/map of all keys that don't belong to a Client-Server
  API-defined event. The map must use string keys (see PDU.to_event/2-4 for
  converting a PDU struct to a similar object).
  """
  def client_event(event) when is_map(event) do
    case Map.take(event, @cs_event_keys) do
      %{"state_key" => nil} = event -> Map.delete(event, "state_key")
      event -> event
    end
  end

  def max_timeline_events, do: Application.get_env(:radio_beam, :max_events)[:timeline]
  def max_state_events, do: Application.get_env(:radio_beam, :max_events)[:state]

  @doc """
  Similar to `put_in/3`, but will create keys in `path` if they do not exist.
  """
  @spec put_nested(Access.t(), list(), any()) :: Access.t()
  def put_nested(data, path, value) do
    put_in(data, Enum.map(path, &Access.key(&1, %{})), value)
  end
end
