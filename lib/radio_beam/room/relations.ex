defmodule RadioBeam.Room.Relations do
  @moduledoc """
  API for querying events that relate to other events in a room.
  """
  alias RadioBeam.Room
  alias RadioBeam.Room.UserTimeline.Event
  alias RadioBeam.Room.View.RelatedEvents

  def get_children(room_id, user_id, event_id, limit, opts) do
    with {:ok, child_event_stream} <- get_child_events(room_id, user_id, event_id) do
      rel_type = Keyword.get(opts, :rel_type)
      event_type = Keyword.get(opts, :event_type)

      get_event = Keyword.fetch!(opts, :get_event)

      comparator = &(&1 >= &2.order_id)

      before_start? =
        maybe_event_comparator(room_id, user_id, Keyword.fetch(opts, :to), comparator, fn _ -> false end, get_event)

      comparator = &(&2.order_id < &1)

      before_end? =
        maybe_event_comparator(room_id, user_id, Keyword.fetch(opts, :from), comparator, fn _ -> true end, get_event)

      # note: we take(limit) *after* sorting, since child_event_stream does
      # not traverse child events in topological order (as of writing,
      # RelatedEvents maps child event IDs in a MapSet (which is unordered).
      #
      # same reasoning for using the filter/reject instead of drop_/take_while
      child_events =
        child_event_stream
        # |> Stream.drop_while(before_start?)
        # |> Stream.take_while(before_end?)
        |> Stream.reject(before_start?)
        |> Stream.filter(before_end?)
        |> Stream.filter(&(filter_rel_type(&1, rel_type) and filter_event_type(&1, event_type)))
        |> apply_order(Keyword.get(opts, :order, :reverse_chronological))
        |> Enum.take(limit)

      # TOIMPL: support for `recurse?` option
      {:ok, child_events, _recurse_depth = 1}
    end
  end

  defp apply_order(event_stream, :chronological), do: Enum.sort(event_stream, {:asc, Event})

  defp apply_order(event_stream, :reverse_chronological), do: Enum.sort(event_stream, {:desc, Event})

  defp maybe_event_comparator(room_id, user_id, {:ok, event_id}, comparator, default, get_event) do
    case get_event.(room_id, user_id, event_id, false) do
      {:ok, event} ->
        &comparator.(event.order_id, &1)

      {:error, :unauthorized} ->
        default
    end
  end

  defp maybe_event_comparator(_room_id, _user_id, :error, _comparator, default, _get_event), do: default

  defp filter_rel_type(_pdu, nil), do: true
  defp filter_rel_type(%{content: %{"m.relates_to" => %{"rel_type" => rel_type}}}, rel_type), do: true
  defp filter_rel_type(_pdu, _rel_type), do: false

  defp filter_event_type(_pdu, nil), do: true
  defp filter_event_type(%{type: event_type}, event_type), do: true
  defp filter_event_type(_pdu, _event_type), do: false

  @doc """
  Get the immediate child events of the given `event_id`s. Returns a map from
  `event_id` to `Enumerable.t(Event.t())`. If an `event_id` is absent from the resulting map,
  it either does not exist or the user does not have permission to view it.
  """
  @spec get_child_events(Room.id(), User.id(), [Room.event_id()] | Room.event_id()) ::
          %{Room.event_id() => Enumerable.t(Event.t())} | {:ok, Enumerable.t(Event.t())} | {:error, :not_found}
  def get_child_events(room_id, user_id, event_ids) when is_list(event_ids) do
    %RelatedEvents{} = relations = RelatedEvents.fetch!(room_id)

    room_id
    |> Room.UserTimeline.map_filter_user_events(user_id, event_ids)
    |> Stream.map(&{&1.id, Map.get(relations.related_by_event_id, &1.id, MapSet.new())})
    |> Map.new(fn {parent_event_id, child_event_ids} ->
      {parent_event_id, Room.UserTimeline.map_filter_user_events(room_id, user_id, child_event_ids)}
    end)
  end

  def get_child_events(room_id, user_id, "$" <> _ = event_id) do
    case get_child_events(room_id, user_id, [event_id]) do
      %{^event_id => related_events_stream} -> {:ok, related_events_stream}
      %{} -> {:error, :not_found}
    end
  end
end
