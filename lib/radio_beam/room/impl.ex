defmodule RadioBeam.Room.Impl do
  @moduledoc """
  Implementation details for Room
  """
  alias RadioBeam.PDU
  alias RadioBeam.Repo.Transaction
  alias RadioBeam.Room
  alias RadioBeam.Room.Core
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.Room.Timeline

  require Logger

  def put_event(%Room{} = room, event), do: put_events(room, [event])

  def put_events(%Room{} = room, events) do
    latest_pdus =
      case PDU.all(room.latest_event_ids) do
        {:ok, pdus} -> pdus
        {:error, _} -> []
      end

    put_result =
      Enum.reduce_while(events, {room, [], latest_pdus}, fn event, {%Room{} = room, pdus, parents} ->
        with {:ok, event} <- Core.authorize(room, event),
             {:ok, pdu} <- EventGraph.append(room, parents, event) do
          room = room |> Core.update_state(pdu) |> Core.put_tip([pdu.event_id])
          {:cont, {room, [pdu | pdus], [pdu]}}
        else
          error -> {:halt, error}
        end
      end)

    with {%Room{} = room, [%PDU{} | _] = pdus, _parents} <- put_result,
         :ok <- assert_no_dup_annotations(pdus),
         {:ok, _} <- persist(room, pdus) do
      {:ok, room, pdus}
    end
  end

  defp assert_no_dup_annotations(pdus) do
    new_annotations = Enum.filter(pdus, &(&1.content["m.relates_to"]["rel_type"] == "m.annotation"))

    new_annotations
    |> Enum.map(& &1.parent_id)
    |> PDU.all()
    |> case do
      {:ok, []} ->
        :ok

      {:ok, annotated} ->
        {:ok, children} = PDU.get_children(annotated, _recurse = 1)
        children_by_parent = Enum.group_by(children, & &1.parent_id)

        duplicate? =
          Enum.any?(new_annotations, fn new_annotation ->
            children_by_parent
            |> Map.get(new_annotation.parent_id, [])
            |> Enum.any?(&dup_annotation?(&1, new_annotation))
          end)

        if duplicate? do
          {:error, :duplicate_annotation}
        else
          :ok
        end

      error ->
        error
    end
  end

  defp dup_annotation?(%PDU{} = child, %PDU{} = annotation) do
    child.type == annotation.type and child.content["m.relates_to"]["key"] == annotation.content["m.relates_to"]["key"] and
      child.sender == annotation.sender
  end

  defp persist(room, pdus) do
    init_txn = Transaction.add_fxn(Transaction.new(), :room, fn -> {:ok, Memento.Query.write(room)} end)

    txn_result =
      pdus
      |> Enum.reduce(init_txn, &persist_pdu_with_side_effects(&1, room, &2))
      |> Transaction.execute()

    with {:error, fxn_name, error} <- txn_result do
      Logger.warning("An error occurred trying to persist an event at #{fxn_name}: #{inspect(error)}")
      {:error, error}
    end
  end

  defp persist_pdu_with_side_effects(%PDU{type: "m.room.canonical_alias"} = pdu, _room, txn) do
    [pdu.content["alias"] | Map.get(pdu.content, "alt_aliases", [])]
    |> Stream.reject(&is_nil/1)
    |> Enum.reduce(txn, &Transaction.add_fxn(&2, "put_alias_#{&1}", fn -> Room.Alias.put(&1, pdu.room_id) end))
    |> Transaction.add_fxn(:pdu, fn -> EventGraph.persist_pdu(pdu) end)
  end

  defp persist_pdu_with_side_effects(%PDU{type: "m.room.redaction"} = pdu, room, txn) do
    txn
    |> Transaction.add_fxn("apply-or-enqueue-redaction-#{pdu.event_id}", fn ->
      case PDU.get(pdu.content["redacts"]) do
        {:ok, to_redact} ->
          try_redact(room, to_redact, pdu)

        {:error, :not_found} ->
          Logger.info("we do not have #{pdu.content["redacts"]}, enqueueing redaction retry job")
          # TODO: also try to backfill?
          RadioBeam.Job.insert(:redactions, __MODULE__, :apply_redaction, [pdu.room_id, pdu.event_id])
      end
    end)
    # TODO: should also mark the m.room.redaction PDU somehow, to indicate to
    # not serve to clients
    |> Transaction.add_fxn(:pdu, fn -> EventGraph.persist_pdu(pdu) end)
  end

  # TOIMPL: add room to published room list if visibility option was set to :public
  defp persist_pdu_with_side_effects(%PDU{} = pdu, _room, txn),
    do: Transaction.add_fxn(txn, :pdu, fn -> EventGraph.persist_pdu(pdu) end)

  def try_redact(room, to_redact, pdu) do
    if Timeline.authz_to_view?(to_redact, pdu.sender) and Core.authz_redact?(room, to_redact.sender, pdu.sender) do
      case EventGraph.redact_pdu(to_redact, pdu, room.version) do
        {:ok, redacted_pdu} ->
          EventGraph.persist_pdu(redacted_pdu)

        {:error, cs} = error ->
          Logger.error("Could not redact an event, enqueueing retry job. Error: #{inspect(cs)}")
          RadioBeam.Job.insert(:redactions, __MODULE__, :apply_redaction, [room.id, pdu.event_id])
          error
      end
    else
      {:error, :unauthorized}
    end
  end
end
