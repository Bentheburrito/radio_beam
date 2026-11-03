defmodule RadioBeam.Database.Mnesia.Tables.RoomThreadParent do
  @moduledoc false

  require Record
  Record.defrecord(:room_thread_parent, __MODULE__, room_id_and_stream_number: nil, event_id: nil)

  @type t() ::
          record(:room_thread_parent,
            room_id_and_stream_number: {RadioBeam.Room.id(), non_neg_integer()},
            event_id: RadioBeam.Room.event_id()
          )

  def opts do
    [
      attributes: room_thread_parent() |> room_thread_parent() |> Keyword.keys(),
      type: :ordered_set
    ]
  end
end
