defmodule RadioBeam.Database.Mnesia.Tables.RoomAlias do
  @moduledoc false

  require Record
  Record.defrecord(:room_alias, __MODULE__, id: nil, room_alias: nil)
  @type alias_tuple() :: {localpart :: String.t(), server_name :: String.t()}

  @type t() :: record(:room_alias, id: alias_tuple(), room_alias: RadioBeam.Room.Alias.t())

  def opts, do: [attributes: room_alias() |> room_alias() |> Keyword.keys(), type: :set]
end
