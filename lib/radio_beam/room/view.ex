defmodule RadioBeam.Room.View do
  alias RadioBeam.Repo
  alias RadioBeam.Repo.Tables.ViewState

  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core
  alias RadioBeam.Room.View.Core.Participating
  alias RadioBeam.Room.View.Core.Timeline

  def handle_pdu(%Room{} = room, %PDU{} = pdu) do
    Core.handle_pdu(room, pdu, view_deps())
  end

  def all_participating(user_id) do
    # TODO: should hide view_state key behind fxn in Participating here?
    Repo.fetch(ViewState, {Participating, user_id})
  end

  def timeline_event_stream(room_id, from) do
    with {:ok, %Room{} = room} <- Repo.fetch(Room, room_id),
         {:ok, %Timeline{} = timeline} <- Repo.fetch(ViewState, {Timeline, room_id}) do
      Timeline.topological_stream(timeline, from, &Room.DAG.fetch!(room.dag, &1))
    end
  end

  defp view_deps do
    %{
      fetch_view: fn key -> Repo.fetch(ViewState, key) end,
      save_view!: fn view_state, key -> Repo.insert!(%ViewState{key: key, value: view_state}) end
    }
  end
end
