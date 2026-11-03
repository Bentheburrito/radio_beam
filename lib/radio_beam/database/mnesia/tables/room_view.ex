defmodule RadioBeam.Database.Mnesia.Tables.RoomView do
  @moduledoc false

  alias RadioBeam.Room.View.Core.InviteStateEvents
  alias RadioBeam.Room.View.Core.RelatedEvents

  require Record
  Record.defrecord(:room_view, __MODULE__, id: nil, room_view: nil)

  @type t() ::
          record(:room_view,
            id: term(),
            room_view: InviteStateEvents.t() | RelatedEvents.t()
          )

  def opts, do: [attributes: room_view() |> room_view() |> Keyword.keys(), type: :set]
end
