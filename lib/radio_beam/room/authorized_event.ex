defmodule RadioBeam.Room.AuthorizedEvent do
  @moduledoc """
  A validated and authorized room message event.
  """

  @attrs ~w|auth_events content id origin_server_ts room_id sender state_key type unsigned|a
  @enforce_keys @attrs
  defstruct @attrs
  @type t() :: %__MODULE__{}

  def new!(event_attrs) do
    struct!(__MODULE__,
      auth_events: Map.fetch!(event_attrs, "auth_events"),
      content: Map.fetch!(event_attrs, "content"),
      id: Map.fetch!(event_attrs, "id"),
      origin_server_ts: Map.fetch!(event_attrs, "origin_server_ts"),
      room_id: Map.fetch!(event_attrs, "room_id"),
      sender: Map.fetch!(event_attrs, "sender"),
      state_key: Map.get(event_attrs, "state_key", :none),
      type: Map.fetch!(event_attrs, "type"),
      unsigned: Map.get(event_attrs, "unsigned", %{})
    )
  end

  def keys, do: @attrs
end
