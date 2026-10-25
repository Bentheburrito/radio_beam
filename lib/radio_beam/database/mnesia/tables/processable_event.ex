defmodule RadioBeam.Database.Mnesia.Tables.ProcessableEvent do
  @moduledoc false

  require Record
  Record.defrecord(:processable_event, __MODULE__, queue_and_event_number_and_event_id: nil, event: nil)

  @type t() ::
          record(:processable_event,
            queue_and_event_number_and_event_id: {RadioBeam.EventHandler.queue(), integer()},
            event: term()
          )

  def opts, do: [attributes: processable_event() |> processable_event() |> Keyword.keys(), type: :ordered_set]
end
