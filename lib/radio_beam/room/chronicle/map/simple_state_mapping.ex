defmodule RadioBeam.Room.Chronicle.Map.SimpleStateMapping do
  @moduledoc """
  Wraps a simple %{{type, state_key} => event_id} room state mapping in a struct
  that can return events, primarily for interop w/ Polyjuice.Util
  """
  alias RadioBeam.Room.AuthorizedEvent

  defstruct mapping: %{}, event_fetcher: nil

  @typep event_fetcher() :: (RadioBeam.Room.event_id() -> {:ok, AuthorizedEvent.t()} | {:error, :not_found})

  @opaque t() :: %__MODULE__{
            event_fetcher: event_fetcher(),
            mapping: %{{String.t(), String.t()} => RadioBeam.Room.event_id()}
          }

  def new(mapping, event_fetcher), do: %__MODULE__{mapping: mapping, event_fetcher: event_fetcher}

  def fetch(%__MODULE__{} = simple_mapping, type, key) do
    case simple_mapping.mapping do
      %{{^type, ^key} => event_id} -> simple_mapping.event_fetcher.(event_id)
      _no_entry -> {:error, :not_found}
    end
  end

  defimpl Polyjuice.Util.RoomState do
    alias RadioBeam.Room.Chronicle.Map.SimpleStateMapping

    def fetch(simple_mapping, type, key), do: SimpleStateMapping.fetch(simple_mapping, type, key)

    def member?(simple_mapping, type, key) do
      case simple_mapping.mapping do
        %{{^type, ^key} => _event_id} -> true
        _no_entry -> false
      end
    end

    def size(simple_mapping), do: map_size(simple_mapping.mapping)
  end
end
