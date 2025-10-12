defmodule RadioBeam.Room.Core.Relationships do
  @moduledoc """
  Metadata about event relationships in the room, **only as it pertains to
  writing new events**. For reading event relations (bundled aggregations,
  etc.) see `RadioBeam.Room.EventRelationships` and
  `RadioBeam.Room.View.Core.RelatedEvents`.
  """

  # children_by_event_id: %{event_id => %{event_type => [event_id_or_type_specific_data]}}
  defstruct children_by_event_id: %{}

  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent

  def new!, do: %__MODULE__{}

  def apply_event(%Room{} = room, %AuthorizedEvent{type: "m.reaction"} = event) do
    %{"key" => key, "event_id" => reacted_to_id} = Map.fetch!(event.content, "m.relates_to")

    related_by_type = get_in(room.relationships.children_by_event_id[reacted_to_id]) || %{}

    prev_reactions = Map.get(related_by_type, "m.reaction", [])

    if sender_already_annotated?(prev_reactions, key, event.sender) do
      {:error, :duplicate_annotation}
    else
      reaction_info = {event.id, key, event.sender}

      related_by_type = Map.update(related_by_type, "m.reaction", [reaction_info], &[reaction_info | &1])

      put_in(room.relationships.children_by_event_id[reacted_to_id], related_by_type)
    end
  end

  # TOIMPL: other relationships

  def apply_event(%Room{} = room, _event), do: room

  defp sender_already_annotated?(reaction_info_list, key, sender) do
    Enum.any?(reaction_info_list, &match?({_event_id, ^key, ^sender}, &1))
  end
end
