defmodule RadioBeam.Database.Mnesia.Tables.RoomAlias do
  @moduledoc false

  require Record
  Record.defrecord(:room_alias, __MODULE__, alias_struct: nil, room_id: nil)

  @type t() :: record(:room_alias, alias_struct: RadioBeam.Room.Alias.t(), room_id: RadioBeam.Room.id())

  def opts, do: [attributes: room_alias() |> room_alias() |> Keyword.keys(), type: :set]
end
