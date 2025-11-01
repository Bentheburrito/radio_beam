defmodule RadioBeam.Room.View.Core.Timeline.Event do
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID

  defstruct [:order_id, :bundled_events] ++ AuthorizedEvent.keys()

  def new!(id, %PDU{event: event}, bundled_events) when is_struct(id, TopologicalID) or id == :unknown do
    struct!(
      __MODULE__,
      event
      |> Map.from_struct()
      |> Map.put(:order_id, id)
      |> Map.put(:bundled_events, bundled_events)
    )
  end

  def compare(%__MODULE__{order_id: %TopologicalID{} = order_id1}, %__MODULE__{order_id: %TopologicalID{} = order_id2}) do
    TopologicalID.compare(order_id1, order_id2)
  end

  def compare(%__MODULE__{order_id: :unknown}, %__MODULE__{order_id: maybe_order_id2}), do: maybe_order_id2 > :unknown

  # TOIMPL: choose client or federation format based on filter
  @cs_event_keys [:content, :event_id, :origin_server_ts, :room_id, :sender, :state_key, :type, :unsigned]
  def to_map(%__MODULE__{} = event, room_version) do
    event
    |> Map.take(@cs_event_keys)
    |> adjust_redacts_key(room_version)
    |> case do
      %{state_key: :none} = event -> Map.delete(event, :state_key)
      event -> event
    end
  end

  @pre_v11_format_versions ~w|1 2 3 4 5 6 7 8 9 10|
  defp adjust_redacts_key(%{type: "m.room.redaction"} = event, room_version)
       when room_version in @pre_v11_format_versions do
    {redacts, content} = Map.pop!(event.content, "redacts")

    event
    |> Map.put(:redacts, redacts)
    |> Map.put(:content, content)
  end

  defp adjust_redacts_key(event, _room_version), do: event
end
