defmodule RadioBeam.Room.View.RelatedEvents do
  @moduledoc """
  Tracks related events as defined by `content.m.relates_to`
  """

  @behaviour RadioBeam.EventHandler

  alias RadioBeam.Room.Database
  alias RadioBeam.Room.PDU

  defstruct related_by_event_id: %{}
  @type t() :: %__MODULE__{}

  def new!, do: %__MODULE__{}

  def fetch!(room_id) do
    case Database.fetch_view({__MODULE__, room_id}) do
      {:ok, %__MODULE__{} = relations} -> relations
      {:error, :not_found} -> new!()
    end
  end

  @impl RadioBeam.EventHandler
  def handle_pdu(%PDU{} = pdu, _) do
    %__MODULE__{} = relations = fetch!(pdu.event.room_id)

    related_by_event_id =
      case pdu.event.content do
        %{"m.relates_to" => %{"event_id" => related_to_id}} ->
          Map.update(
            relations.related_by_event_id,
            related_to_id,
            MapSet.new([pdu.event.id]),
            &MapSet.put(&1, pdu.event.id)
          )

        _ ->
          relations.related_by_event_id
      end

    Database.upsert_view({__MODULE__, pdu.event.room_id}, struct!(relations, related_by_event_id: related_by_event_id))
  end

  @impl RadioBeam.EventHandler
  # handle_pdu is idempotent - can just reapply events
  def reset_to(event_number), do: {:ok, event_number}
end
