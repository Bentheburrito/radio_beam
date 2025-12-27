defmodule RadioBeam.Room.EventRelationships do
  @moduledoc """
  Functions for working with relationships between events, such as aggregating
  them.
  """

  require RadioBeam

  @aggregable_rel_types ~w|m.thread m.replace m.reference|
  def aggregable?(%{content: %{"m.relates_to" => %{"rel_type" => type}}}),
    do: type in @aggregable_rel_types

  def aggregable?(%{content: %{}}), do: false

  def get_aggregations(%{} = event, user_id, child_events) do
    grouped_events = group_events_by_relation_aggregator(event, user_id, child_events)
    grouped_events = handle_special_cases(event, grouped_events)

    for {{rel_type, aggregator, init_acc}, child_events} <- grouped_events, reduce: event do
      event ->
        aggregation = Enum.reduce(child_events, init_acc, aggregator)
        RadioBeam.AccessExtras.put_nested(event, [:unsigned, "m.relations", rel_type], aggregation)
    end
  end

  defp group_events_by_relation_aggregator(event, user_id, child_events) do
    key_fxn = fn child_event ->
      rel_type = child_event.content["m.relates_to"]["rel_type"]

      case get_aggregator_by_rel_type(rel_type, event, user_id) do
        {aggregator, init_acc} -> {rel_type, aggregator, init_acc}
        :no_known_aggregator -> {rel_type, :no_known_aggregator}
      end
    end

    Enum.group_by(child_events, key_fxn)
  end

  # note: for some reason `m.annotation`s are not aggregated by the homeserver,
  # as described in [the spec](https://spec.matrix.org/v1.12/client-server-api/#server-side-aggregation-of-mannotation-relationships).
  defp get_aggregator_by_rel_type("m.thread", parent, user_id),
    do: {&aggregate_thread(&1, &2, user_id), init_thread_acc(parent, user_id)}

  defp get_aggregator_by_rel_type("m.replace", _parent, _user_id), do: {&aggregate_replace/2, nil}
  defp get_aggregator_by_rel_type("m.reference", _parent, _user_id), do: {&aggregate_reference/2, %{"chunk" => []}}
  defp get_aggregator_by_rel_type(_rel_type, _parent, _user_id), do: :no_known_aggregator

  defp aggregate_replace(%{} = edit1, nil), do: edit1

  defp aggregate_replace(%{} = edit1, %{} = edit2) do
    cond do
      edit1.origin_server_ts > edit2.origin_server_ts ->
        edit1

      edit1.origin_server_ts == edit2.origin_server_ts and edit1.id > edit2.id ->
        edit1

      :else ->
        edit2
    end
  end

  defp aggregate_thread(event, %{} = acc, user_id) do
    latest_event = if event.origin_server_ts >= acc.latest_event.origin_server_ts, do: event, else: acc.latest_event

    %{
      acc
      | latest_event: latest_event,
        count: acc.count + 1,
        current_user_participated: acc.current_user_participated or event.sender == user_id
    }
  end

  defp init_thread_acc(parent, user_id),
    do: %{latest_event: parent, count: 0, current_user_participated: user_id == parent.sender}

  defp aggregate_reference(%{} = child_event, %{"chunk" => chunk}) do
    %{"chunk" => [child_event.id | chunk]}
  end

  # If the original event is redacted, any m.replace relationship should not be
  # bundled with it (whether or not any subsequent replacements are themselves
  # redacted). Note that this behaviour is specific to the m.replace relationship
  defp handle_special_cases(%{content: content}, %{"m.replace" => _} = grouped_events)
       when map_size(content) == 0 do
    Map.delete(grouped_events, "m.replace")
  end

  defp handle_special_cases(%{}, grouped_events), do: grouped_events
end
