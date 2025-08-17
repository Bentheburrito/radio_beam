defmodule RadioBeam.Room.Core.Redactions do
  @moduledoc """
  Functional core redaction-specific actions on %Room{}s
  """
  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.DAG
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.State

  defstruct pending: %{}

  # need to map (to_redact_id => redaction_event_id), because we shouldn't send
  # the redaction_event to clients until we receive to_redact. But maybe that's
  # more of a Timeline/read model concern...
  @opaque t() :: %__MODULE__{pending: %{Room.event_id() => AuthorizedEvent.t()}}

  def new!, do: %__MODULE__{}

  def apply_or_queue(%Room{} = room, redaction_event) do
    event_id_to_redact = Map.fetch!(redaction_event.content, "redacts")

    case DAG.fetch(room.dag, event_id_to_redact) do
      {:ok, %PDU{} = pdu} -> apply_redaction(room, redaction_event, pdu)
      {:error, :not_found} -> update_in(room.redactions.pending, &Map.put(&1, event_id_to_redact, redaction_event))
    end
  end

  def apply_any_pending(%Room{} = room, event_id) do
    case Map.fetch(room.redactions.pending, event_id) do
      {:ok, redaction_event} -> apply_redaction(room, redaction_event, DAG.fetch!(room.dag, event_id))
      :error -> room
    end
  end

  defp apply_redaction(room, %AuthorizedEvent{type: "m.room.redaction"} = redaction, pdu) do
    if should_apply_redaction?(room, redaction.sender, pdu.event.sender) do
      {:ok, redacted_pdu} = room.state |> State.room_version() |> RoomVersion.redact(pdu)

      struct!(room,
        dag: DAG.replace_pdu!(room.dag, redacted_pdu),
        state: State.replace_pdu!(room.state, redacted_pdu),
        redactions: struct!(room.redactions, pending: Map.delete(room.redactions.pending, redacted_pdu.event.id))
      )
    else
      # TODO: track un-applied redactions somehow w/ a reason?
      update_in(room.redactions.pending, &Map.delete(&1, pdu.event.id))
    end
  end

  defp should_apply_redaction?(%Room{} = room, original_sender, redactor) do
    # TOOD: explicitly pass down dependency fxn to check admins
    redactor in RadioBeam.admins() or
      State.user_has_power?(room.state, ["redact"], redactor) or
      original_sender == redactor
  end
end
