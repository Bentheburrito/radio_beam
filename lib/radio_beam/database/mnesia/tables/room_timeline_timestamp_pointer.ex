defmodule RadioBeam.Database.Mnesia.Tables.RoomTimestampPointer do
  @moduledoc false

  require Record
  Record.defrecord(:room_timestamp_pointer, __MODULE__, room_id_and_timestamp: nil, event_id: nil)

  @type t() ::
          record(:room_timestamp_pointer,
            room_id_and_timestamp: {RadioBeam.Room.id(), integer()},
            event_id: RadioBeam.Room.event_id()
          )

  def opts do
    [
      attributes: room_timestamp_pointer() |> room_timestamp_pointer() |> Keyword.keys(),
      type: :ordered_set
    ]
  end
end
