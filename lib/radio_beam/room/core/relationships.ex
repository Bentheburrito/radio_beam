defmodule RadioBeam.Room.Core.Relationships do
  @moduledoc """
  Constraints around event relationships in the room **only as it pertains to
  writing new events**. For reading event relations (bundled aggregations,
  etc.) see `RadioBeam.Room.EventRelationships` and
  `RadioBeam.Room.RelatedEvents`.
  """

  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent

  def apply_event(%Room{} = room, %AuthorizedEvent{type: "m.reaction"} = event) do
    %{"key" => key, "event_id" => reacted_to_id} = Map.fetch!(event.content, "m.relates_to")

    related_by_type = Room.Chronicle.get_relation(room.chronicle, reacted_to_id) || %{}

    prev_reactions = Map.get(related_by_type, "m.reaction", [])

    if sender_already_annotated?(prev_reactions, key, event.sender) do
      {:error, :duplicate_annotation}
    else
      reaction_info = {event.id, key, event.sender}

      related_by_type = Map.update(related_by_type, "m.reaction", [reaction_info], &[reaction_info | &1])

      put_in(room.chronicle, Room.Chronicle.put_relation(room.chronicle, reacted_to_id, related_by_type))
    end
  end

  def apply_event(%Room{} = room, %AuthorizedEvent{content: %{"m.relates_to" => %{"rel_type" => "m.thread"}}} = event) do
    case Room.Chronicle.fetch_event(room.chronicle, event.content["m.relates_to"]["event_id"]) do
      {:ok, %{content: %{"m.relates_to" => _}}} -> {:error, :cannot_thread_child_event}
      {:ok, _event} -> room
      {:error, :not_found} -> {:error, :thread_parent_unknown}
    end
  end

  # TOIMPL: other relationships

  def apply_event(%Room{} = room, _event), do: room

  defp sender_already_annotated?(reaction_info_list, key, sender) do
    Enum.any?(reaction_info_list, &match?({_event_id, ^key, ^sender}, &1))
  end
end
