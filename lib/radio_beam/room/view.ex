defmodule RadioBeam.Room.View do
  alias RadioBeam.Repo
  alias RadioBeam.Repo.Tables.ViewState

  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core
  alias RadioBeam.Room.View.Core.Participating
  alias RadioBeam.Room.View.Core.RelatedEvents
  alias RadioBeam.Room.View.Core.Timeline

  def handle_pdu(%Room{} = room, %PDU{} = pdu) do
    Core.handle_pdu(room, pdu, view_deps())
  end

  def all_participating(user_id) do
    # TODO: should hide view_state key behind fxn in Participating here?
    Repo.fetch(ViewState, {Participating, user_id})
  end

  def latest_known_join_pdu(room_id, user_id) do
    with {:ok, %Participating{} = participating} <- Repo.fetch(ViewState, {Participating, user_id}),
         :error <- Map.fetch(participating.latest_known_join_pdus, room_id) do
      {:error, :never_joined}
    end
  end

  def timeline_event_stream(room_id, from) do
    with {:ok, %Room{} = room} <- Repo.fetch(Room, room_id),
         {:ok, %Timeline{} = timeline} <- Repo.fetch(ViewState, {Timeline, room_id}) do
      Timeline.topological_stream(timeline, from, &Room.DAG.fetch!(room.dag, &1))
    end
  end

  @spec child_events(Room.id(), Room.event_id() | [Room.event_id()]) ::
          MapSet.t(Room.event_iod()) | %{Room.event_id() => MapSet.t(Room.event_id())}
  def child_events(room_id, event_ids) when is_list(event_ids) do
    with {:ok, %RelatedEvents{} = relations} <- Repo.fetch(ViewState, {RelatedEvents, room_id}) do
      Map.take(relations.related_by_event_id, event_ids)
    end
  end

  def child_events(room_id, event_id) do
    case child_events(room_id, [event_id]) do
      %{^event_id => %MapSet{} = related_event_ids} -> related_event_ids
      %{} -> MapSet.new()
    end
  end

  defp view_deps do
    %{
      fetch_view: fn key -> Repo.fetch(ViewState, key) end,
      save_view!: fn view_state, key -> Repo.insert!(%ViewState{key: key, value: view_state}) end
    }
  end
end
