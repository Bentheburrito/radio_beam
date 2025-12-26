defmodule RadioBeam.Room.View do
  @moduledoc false
  alias RadioBeam.PubSub
  alias RadioBeam.Room
  alias RadioBeam.Room.Database
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core
  alias RadioBeam.Room.View.Core.Participating
  alias RadioBeam.Room.View.Core.RelatedEvents
  alias RadioBeam.Room.View.Core.Timeline
  alias RadioBeam.User

  @type key() :: term()
  @type t() :: Participating.t() | RelatedEvents.t() | Timeline.t()

  def handle_pdu(%Room{} = room, %PDU{} = pdu) do
    Core.handle_pdu(room, pdu, deps())
  end

  def all_participating(user_id) do
    # TODO: should hide view_state key behind fxn in Participating here?
    Database.fetch_view({Participating, user_id})
  end

  def latest_known_join_pdu(room_id, user_id) do
    with {:ok, %Participating{} = participating} <- Database.fetch_view({Participating, user_id}),
         :error <- Map.fetch(participating.latest_known_join_pdus, room_id) do
      {:error, :never_joined}
    end
  end

  def timeline_event_stream(room_id, user_id, from) do
    with {:ok, %Room{} = room} <- Database.fetch_room(room_id),
         {:ok, %Timeline{} = timeline} <- Database.fetch_view({Timeline, room_id}) do
      {:ok, Timeline.topological_stream(timeline, user_id, from, &Room.DAG.fetch!(room.dag, &1))}
    end
  end

  def timeline_event_stream!(room_id, user_id, from) do
    case timeline_event_stream(room_id, user_id, from) do
      {:ok, stream} -> stream
      {:error, error} -> raise error
    end
  end

  def get_events(room_id, user_id, event_ids) do
    with {:ok, %Room{} = room} <- Database.fetch_room(room_id),
         {:ok, %Timeline{} = timeline} <- Database.fetch_view({Timeline, room_id}) do
      {:ok, Timeline.get_visible_events(timeline, event_ids, user_id, &Room.DAG.fetch!(room.dag, &1))}
    end
  end

  def get_events!(room_id, user_id, event_ids) do
    case get_events(room_id, user_id, event_ids) do
      {:ok, event_stream} -> event_stream
      {:error, error} -> raise error
    end
  end

  def nearest_events_stream(room_id, user_id, timestamp, direction) do
    with {:ok, %Timeline{} = timeline} <- Database.fetch_view({Timeline, room_id}) do
      {:ok, Timeline.stream_event_ids_closest_to_ts(timeline, user_id, timestamp, direction)}
    end
  end

  @doc """
  Get the immediate child events of the given `event_id`s. Returns a map from
  `event_id` to `Enumerable.t(Event.t())`. If an `event_id` is absent from the resulting map,
  it either does not exist or the user does not have permission to view it.
  """
  @spec get_child_events(Room.id(), User.id(), [Room.event_id()] | Room.event_id()) ::
          %{Room.event_id() => Enumerable.t(Event.t())} | {:ok, Enumerable.t(Event.t())} | {:error, :not_found}
  def get_child_events(room_id, user_id, event_ids) when is_list(event_ids) do
    with {:ok, %Room{} = room} <- Database.fetch_room(room_id),
         {:ok, %Timeline{} = timeline} <- Database.fetch_view({Timeline, room_id}),
         {:ok, %RelatedEvents{} = relations} <- Database.fetch_view({RelatedEvents, room_id}) do
      fetch_pdu! = &Room.DAG.fetch!(room.dag, &1)

      timeline
      |> Timeline.get_visible_events(event_ids, user_id, fetch_pdu!)
      |> Stream.map(&{&1.id, Map.get(relations.related_by_event_id, &1.id, MapSet.new())})
      |> Map.new(fn {parent_event_id, child_event_ids} ->
        visible_child_event_stream =
          Timeline.get_visible_events(timeline, child_event_ids, user_id, fetch_pdu!)

        {parent_event_id, visible_child_event_stream}
      end)
    end
  end

  def get_child_events(room_id, user_id, "$" <> _ = event_id) do
    case get_child_events(room_id, user_id, [event_id]) do
      %{^event_id => related_events_stream} -> {:ok, related_events_stream}
      %{} -> {:error, :not_found}
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
