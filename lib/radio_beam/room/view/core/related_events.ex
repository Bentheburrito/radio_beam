defmodule RadioBeam.Room.View.Core.RelatedEvents do
  @moduledoc """
  Tracks related events as defined by `content.m.relates_to`
  """
  defstruct related_by_event_id: %{}

  alias RadioBeam.Room.PDU

  def new!, do: %__MODULE__{}

  def key_for(%{id: room_id}, _pdu), do: {:ok, {__MODULE__, room_id}}

  def handle_pdu(%__MODULE__{} = relations, %{id: room_id}, pdu) do
    related_by_event_id =
      case pdu.event.content do
        %{"m.relates_to" => %{"event_id" => related_to_id}} ->
          Map.update(
            relations.related_by_event_id,
            related_to_id,
            MapSet.new([pdu.event.id], &MapSet.put(&1, pdu.event.id))
          )

        _ ->
          relations.related_by_event_id
      end

    struct!(relations, related_by_event_id: related_by_event_id)
  end
end
