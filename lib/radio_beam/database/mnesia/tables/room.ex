defmodule RadioBeam.Database.Mnesia.Tables.Room do
  @moduledoc false

  require Record
  Record.defrecord(:room, __MODULE__, id: nil, room: nil)

  @type t() :: record(:room, id: RadioBeam.Room.id(), room: RadioBeam.Room.t())

  def opts, do: [attributes: room() |> room() |> Keyword.keys(), type: :set]
end
