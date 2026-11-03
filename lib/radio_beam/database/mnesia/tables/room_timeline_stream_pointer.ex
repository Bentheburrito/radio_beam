defmodule RadioBeam.Database.Mnesia.Tables.RoomTimelineStreamPointer do
  @moduledoc false

  require Record
  Record.defrecord(:room_timeline_stream_pointer, __MODULE__, room_id_and_stream_number: nil, event_id: nil)

  @type t() ::
          record(:room_timeline_stream_pointer,
            room_id_and_stream_number: {RadioBeam.Room.id(), integer()},
            event_id: RadioBeam.Room.event_id()
          )

  def opts do
    [
      attributes: room_timeline_stream_pointer() |> room_timeline_stream_pointer() |> Keyword.keys(),
      type: :ordered_set
    ]
  end
end
