defmodule RadioBeam.Database.Mnesia.Tables.RoomView do
  @moduledoc false

  alias RadioBeam.Room.View.Core.Participating
  alias RadioBeam.Room.View.Core.RelatedEvents
  alias RadioBeam.Room.View.Core.Timeline

  require Record
  Record.defrecord(:room_view, __MODULE__, id: nil, room_view: nil)

  @type t() :: record(:room_view, id: term(), room_view: Participating.t() | RelatedEvents.t() | Timeline.t())

  def opts, do: [attributes: room_view() |> room_view() |> Keyword.keys(), type: :set]
end
