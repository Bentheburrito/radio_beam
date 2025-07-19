defmodule RadioBeam.Room.PDU do
  alias RadioBeam.Room.AuthorizedEvent

  @attrs ~w|prev_event_ids event|a
  @enforce_keys @attrs
  defstruct @attrs

  def new!(%AuthorizedEvent{} = event, prev_event_ids) when is_list(prev_event_ids) do
    struct!(__MODULE__, prev_event_ids: prev_event_ids, event: event)
  end
end
