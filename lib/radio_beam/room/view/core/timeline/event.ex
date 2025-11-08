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
  @cs_event_keys [:content, :origin_server_ts, :room_id, :sender, :state_key, :type, :unsigned]
  def to_map(%__MODULE__{} = event) do
    event
    |> Map.take(@cs_event_keys)
    |> Map.put(:event_id, event.id)
    |> adjust_redacts_key()
    |> case do
      %{state_key: :none} = event -> Map.delete(event, :state_key)
      event -> event
    end
  end

  defp adjust_redacts_key(%{type: "m.room.redaction"} = event),
    do: Map.put(event, :redacts, get_in(event.content["redacts"]))

  defp adjust_redacts_key(event), do: event

  defimpl Jason.Encoder do
    alias RadioBeam.Room.View.Core.Timeline.Event

    def encode(event, opts), do: event |> Event.to_map() |> Jason.Encode.map(opts)
  end
end
