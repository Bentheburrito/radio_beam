defmodule RadioBeam.Room.View do
  @moduledoc false
  alias RadioBeam.Room
  alias RadioBeam.Room.UserTimeline
  alias RadioBeam.Room.UserTimeline.Event
  alias RadioBeam.Room.View.RelatedEvents
  alias RadioBeam.User

  @type key() :: term()
  @type t() :: RelatedEvents.t()

  def timeline_event_stream(room_id, user_id, from), do: UserTimeline.stream_user_events(room_id, user_id, from: from)

  def get_events(room_id, user_id, event_ids, _bundle_aggregations? \\ true),
    do: UserTimeline.map_filter_user_events(room_id, user_id, event_ids)

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
    |> UserTimeline.map_filter_user_events(user_id, event_ids)
    |> Stream.map(&{&1.id, Map.get(relations.related_by_event_id, &1.id, MapSet.new())})
    |> Map.new(fn {parent_event_id, child_event_ids} ->
      {parent_event_id, UserTimeline.map_filter_user_events(room_id, user_id, child_event_ids)}
    end)
  end

  def get_child_events(room_id, user_id, "$" <> _ = event_id) do
    case get_child_events(room_id, user_id, [event_id]) do
      %{^event_id => related_events_stream} -> {:ok, related_events_stream}
      %{} -> {:error, :not_found}
    end
  end
end
