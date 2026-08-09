defmodule RadioBeam.Database.Mnesia.Tables.EventHandlerState do
  @moduledoc false

  require Record
  Record.defrecord(:event_handler_state, __MODULE__, queue: nil, state: nil)

  @type t() ::
          record(:event_handler_state, queue: RadioBeam.EventHandler.queue(), state: RadioBeam.EventHandler.State.t())

  def opts, do: [attributes: event_handler_state() |> event_handler_state() |> Keyword.keys(), type: :set]
end
