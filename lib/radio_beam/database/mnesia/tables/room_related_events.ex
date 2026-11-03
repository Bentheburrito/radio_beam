defmodule RadioBeam.Database.Mnesia.Tables.RoomRelatedEvents do
  @moduledoc false

  alias RadioBeam.Room.View.Core.RelatedEvents

  require Record
  Record.defrecord(:room_related_events, __MODULE__, room_id: nil, related_events: nil)

  @type t() :: record(:room_related_events, room_id: term(), related_events: RelatedEvents.t())

  def opts, do: [attributes: room_related_events() |> room_related_events() |> Keyword.keys(), type: :set]
end
