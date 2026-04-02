defmodule RadioBeam.Room.Core.Redactions do
  @moduledoc """
  Functional core redaction-specific actions on %Room{}s
  """
  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Chronicle

  defstruct pending: %{}

  # need to map (to_redact_id => redaction_event), because we shouldn't send
  # the redaction_event to clients until we receive to_redact.
  @opaque t() :: %__MODULE__{pending: %{Room.event_id() => AuthorizedEvent.t()}}

  def new!, do: %__MODULE__{}

  def apply_or_queue(%Room{} = room, redaction_event) do
    event_id_to_redact = Map.fetch!(redaction_event.content, "redacts")

    case Chronicle.fetch_event(room.chronicle, event_id_to_redact) do
      {:ok, %AuthorizedEvent{} = event_to_redact} ->
        apply_redaction(room, redaction_event, event_to_redact)

      {:error, :not_found} ->
        {:queued, update_in(room.redactions.pending, &Map.put(&1, event_id_to_redact, redaction_event))}
    end
  end

  def apply_any_pending(%Room{} = room, event_id) do
    case Map.fetch(room.redactions.pending, event_id) do
      {:ok, redaction_event} ->
        {:ok, event_to_redact} = Chronicle.fetch_event(room.chronicle, event_id)
        apply_redaction(room, redaction_event, event_to_redact)

      :error ->
        {:not_applied, room}
    end
  end

  defp apply_redaction(room, %AuthorizedEvent{type: "m.room.redaction"} = redaction, event_to_redact) do
    if should_apply_redaction?(room, redaction, event_to_redact.sender) do
      {:ok, redacted_event} = room.chronicle |> Chronicle.room_version() |> RoomVersion.redact(event_to_redact)

      {:applied,
       struct!(room,
         chronicle: Chronicle.replace!(room.chronicle, redacted_event),
         redactions: struct!(room.redactions, pending: Map.delete(room.redactions.pending, redacted_event.id))
       ), redaction}
    else
      # TODO: track un-applied redactions somehow w/ a reason?
      {:not_applied, update_in(room.redactions.pending, &Map.delete(&1, event_to_redact.id))}
    end
  end

  defp should_apply_redaction?(%Room{} = room, %{sender: redactor, id: redaction_id}, original_sender) do
    # is there a case where we would have accepted a redaction event without
    # knowing the state of the room at its send time? I don't *think* so...
    state_mapping = Chronicle.get_state_event_mapping_before(room.chronicle, redaction_id)
    room_version = Chronicle.room_version(room.chronicle)

    # TOOD: explicitly pass down dependency fxn to check admins
    redactor in RadioBeam.Config.admins() or
      user_has_power?(room_version, state_mapping, ["redact"], redactor, _state_event? = false) or
      original_sender == redactor
  end

  defp user_has_power?(room_version, state_mapping, power_level_content_path, user_id, state_event?) do
    RoomVersion.has_power?(room_version, user_id, power_level_content_path, state_event?, state_mapping)
  end
end
