defmodule RadioBeam.Room.PDU do
  @moduledoc false
  alias RadioBeam.Room.AuthorizedEvent

  @attrs ~w|prev_event_ids event stream_number|a
  @enforce_keys @attrs
  defstruct @attrs
  @type t() :: %__MODULE__{}

  def new!(%AuthorizedEvent{} = event, prev_event_ids, stream_number) when is_list(prev_event_ids) do
    struct!(__MODULE__, prev_event_ids: prev_event_ids, event: event, stream_number: stream_number)
  end
end
