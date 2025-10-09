defmodule RadioBeam.Room.PDU.Relationships do
  @moduledoc """
  Functions for working with relationships between events, such as aggregating
  them.
  """
  alias RadioBeam.Room.PDU

  require RadioBeam

  @aggregable_rel_types ~w|m.thread m.replace m.reference|
  def aggregable?(%PDU{event: %{content: %{"m.relates_to" => %{"rel_type" => type}}}}),
    do: type in @aggregable_rel_types

  def aggregable?(%PDU{}), do: false

  def get_aggregations(%PDU{} = pdu, user_id, child_pdus) do
    grouped_pdus = group_pdus_by_relation_aggregator(pdu, user_id, child_pdus)
    grouped_pdus = handle_special_cases(pdu, grouped_pdus)

    for {{rel_type, aggregator, init_acc}, child_pdus} <- grouped_pdus, reduce: pdu do
      pdu ->
        aggregation = Enum.reduce(child_pdus, init_acc, aggregator)
        RadioBeam.put_nested(pdu, [:unsigned, "m.relations", rel_type], aggregation)
    end
  end

  defp group_pdus_by_relation_aggregator(pdu, user_id, child_pdus) do
    key_fxn = fn child_pdu ->
      rel_type = child_pdu.event.content["m.relates_to"]["rel_type"]

      case get_aggregator_by_rel_type(rel_type, pdu, user_id) do
        {aggregator, init_acc} -> {rel_type, aggregator, init_acc}
        :no_known_aggregator -> {rel_type, :no_known_aggregator}
      end
    end

    Enum.group_by(child_pdus, key_fxn)
  end

  # note: for some reason `m.annotation`s are not aggregated by the homeserver,
  # as described in [the spec](https://spec.matrix.org/v1.12/client-server-api/#server-side-aggregation-of-mannotation-relationships).
  defp get_aggregator_by_rel_type("m.thread", parent, user_id),
    do: {&aggregate_thread(&1, &2, user_id), init_thread_acc(parent, user_id)}

  defp get_aggregator_by_rel_type("m.replace", parent, _user_id), do: {&aggregate_replace/2, parent}
  defp get_aggregator_by_rel_type("m.reference", _parent, _user_id), do: {&aggregate_reference/2, %{"chunk" => []}}
  defp get_aggregator_by_rel_type(_rel_type, _parent, _user_id), do: :no_known_aggregator

  defp aggregate_replace(%PDU{} = edit1, %PDU{} = edit2) do
    cond do
      edit1.event.origin_server_ts > edit2.event.origin_server_ts ->
        edit1

      edit1.event.origin_server_ts == edit2.event.origin_server_ts and edit1.event.event_id > edit2.event.event_id ->
        edit1

      :else ->
        edit2
    end
  end

  defp aggregate_thread(%PDU{} = pdu, %{} = acc, user_id) do
    # latest_event = if PDU.compare(pdu, acc.latest_event) == :gt, do: pdu, else: acc.latest_event
    latest_event = if pdu.stream_number > acc.latest_event.stream_number, do: pdu, else: acc.latest_event

    %{
      acc
      | latest_event: latest_event,
        count: acc.count + 1,
        current_user_participated: acc.current_user_participated or pdu.event.sender == user_id
    }
  end

  defp init_thread_acc(parent, user_id),
    do: %{latest_event: parent, count: 0, current_user_participated: user_id == parent.event.sender}

  defp aggregate_reference(%PDU{} = child_pdu, %{"chunk" => chunk}) do
    %{"chunk" => [child_pdu.event_id | chunk]}
  end

  # If the original event is redacted, any m.replace relationship should not be
  # bundled with it (whether or not any subsequent replacements are themselves
  # redacted). Note that this behaviour is specific to the m.replace relationship
  defp handle_special_cases(%PDU{event: %{content: content}}, %{"m.replace" => _} = grouped_pdus)
       when map_size(content) == 0 do
    Map.delete(grouped_pdus, "m.replace")
  end

  defp handle_special_cases(%PDU{}, grouped_pdus), do: grouped_pdus
end
