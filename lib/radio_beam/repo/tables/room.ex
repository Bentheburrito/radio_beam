defmodule RadioBeam.Repo.Tables.Room do
  use Memento.Table,
    attributes: [:id, :room],
    type: :set

  def dump!(%RadioBeam.Room{} = room), do: %__MODULE__{id: room.id, room: room}
  def load!(%__MODULE__{room: room}), do: room
end
