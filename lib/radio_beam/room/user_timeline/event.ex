defmodule RadioBeam.Room.UserTimeline.Event do
  @moduledoc false
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.EventRelationships
  alias RadioBeam.Room.PDU

  defstruct [:order_id, :bundled_events, :bundled_for] ++ AuthorizedEvent.keys()

  def new!(%PDU{event: event, stream_number: stream_number}, bundled_events, bundled_for) do
    struct!(
      __MODULE__,
      event
      |> Map.from_struct()
      |> Map.put(:order_id, stream_number)
      |> Map.put(:bundled_events, bundled_events)
      |> Map.put(:bundled_for, bundled_for)
    )
  end

  def compare(%__MODULE__{order_id: order_id}, %__MODULE__{order_id: order_id}), do: :eq

  def compare(%__MODULE__{order_id: order_id1}, %__MODULE__{order_id: order_id2}) do
    if order_id1 > order_id2, do: :gt, else: :lt
  end

  # TOIMPL: choose client or federation format based on filter
  @cs_event_keys [:content, :origin_server_ts, :room_id, :sender, :state_key, :type, :unsigned]
  def to_map(%__MODULE__{} = event) do
    event
    |> EventRelationships.get_aggregations(event.bundled_for, event.bundled_events)
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

  defimpl JSON.Encoder do
    alias RadioBeam.Room.UserTimeline.Event

    def encode(event, encoder), do: event |> Event.to_map() |> JSON.Encoder.Map.encode(encoder)
  end
end
