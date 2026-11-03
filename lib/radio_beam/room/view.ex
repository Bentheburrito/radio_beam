defmodule RadioBeam.Room.View do
  @moduledoc false
  alias RadioBeam.PubSub
  alias RadioBeam.Room
  alias RadioBeam.Room.Database
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core
  alias RadioBeam.Room.View.Core.InviteStateEvents
  alias RadioBeam.Room.View.Timeline
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Room.View.RelatedEvents
  alias RadioBeam.Room.View.Threads
  alias RadioBeam.User

  @type key() :: term()
  @type t() :: InviteStateEvents.t() | RelatedEvents.t()

  def handle_pdu(room_id, state_mapping_at_pdu, %PDU{} = pdu) do
    Core.handle_pdu(room_id, state_mapping_at_pdu, pdu, deps())
  end

  def timeline_event_stream(room_id, user_id, from), do: Timeline.stream_user_events(room_id, user_id, from: from)

  def get_events(room_id, user_id, event_ids, _bundle_aggregations? \\ true),
    do: Timeline.map_filter_user_events(room_id, user_id, event_ids)

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
    |> Timeline.map_filter_user_events(user_id, event_ids)
    |> Stream.map(&{&1.id, Map.get(relations.related_by_event_id, &1.id, MapSet.new())})
    |> Map.new(fn {parent_event_id, child_event_ids} ->
      {parent_event_id, Timeline.map_filter_user_events(room_id, user_id, child_event_ids)}
    end)
  end

  def get_child_events(room_id, user_id, "$" <> _ = event_id) do
    case get_child_events(room_id, user_id, [event_id]) do
      %{^event_id => related_events_stream} -> {:ok, related_events_stream}
      %{} -> {:error, :not_found}
    end
  end

  def get_thread_event_ids(room_id, user_id, include, limit, from) when is_integer(limit) and limit in 0..50 do
    event_ids = room_id |> Threads.stream_event_ids() |> drop_until_from(from)

    room_id
    |> Timeline.map_filter_user_events(user_id, event_ids)
    |> Stream.map(&Event.to_map/1)
    |> filter_by_include(include)
    |> Enum.take(limit)
  end

  defp drop_until_from(event_ids, :latest), do: event_ids

  defp drop_until_from(event_ids, from_event_id) do
    event_ids
    |> Stream.drop_while(&(&1 != from_event_id))
    |> Stream.drop(1)
  end

  defp filter_by_include(event_maps, :all), do: event_maps

  defp filter_by_include(event_maps, :participated) do
    Stream.filter(event_maps, &get_in(&1, [:unsigned, "m.relations", "m.thread", :current_user_participated]))
  end

  @stripped_state_event_keys ~w|content sender state_key type|a
  def get_invite_state(room_id, user_id) do
    with {:ok, %InviteStateEvents{} = invite_state} <- Database.fetch_view({InviteStateEvents, room_id}) do
      state_events =
        InviteStateEvents.stripped_state_types()
        |> Stream.reject(&(&1 == "m.room.member"))
        |> Stream.map(&{&1, ""})
        |> Stream.concat([{"m.room.member", user_id}])
        |> Stream.filter(&is_map_key(invite_state.mapping, &1))
        |> Stream.map(&Map.fetch!(invite_state.mapping, &1))
        |> Enum.map(&Map.take(&1.event, @stripped_state_event_keys))

      {:ok, state_events}
    end
  end

  defp deps do
    %{
      fetch_view: &Database.fetch_view/1,
      save_view!: &save_view!/2,
      broadcast!: &PubSub.broadcast/2
    }
  end

  defp save_view!(view_state, key), do: Database.upsert_view(key, view_state)
end
