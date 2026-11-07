defmodule RadioBeam.Room.Database do
  @moduledoc """
  A behaviour for implementing a persistence backend for the `RadioBeam.Room`
  bounded context.
  """
  alias RadioBeam.Room

  @type ensure_room_exists?() :: boolean()

  @callback upsert_room(Room.t()) :: :ok
  @callback fetch_room(Room.id()) :: {:ok, Room.t()} | {:error, :not_found}
  @callback upsert_related_events(Room.id(), Room.RelatedEvents.t()) :: :ok
  @callback fetch_related_events(Room.id()) :: {:ok, Room.RelatedEvents.t()} | {:error, :not_found}
  @callback create_alias(Room.Alias.t(), Room.id(), ensure_room_exists?()) ::
              :ok | {:error, :alias_in_use | :room_does_not_exist}
  @callback rebind_aliases(Room.id(), Room.id()) :: :ok
  @callback fetch_room_id_by_alias(Room.Alias.t()) :: {:ok, Room.t()} | {:error, :not_found}
  @callback upsert_room_timeline_stream_pointer(Room.id(), integer(), Room.event_id()) :: :ok
  @callback stream_room_timeline(Room.id(), Keyword.t()) :: Enumerable.t(Room.event_id())
  @callback upsert_room_timestamp_pointer(Room.id(), non_neg_integer(), Room.event_id()) :: :ok
  @callback stream_room_event_ids_from_timestamp(Room.id(), non_neg_integer(), :backward | :forward, Keyword.t()) ::
              Enumerable.t(Room.event_id())
  @callback upsert_room_thread_parent(Room.id(), non_neg_integer(), Room.event_id()) :: :ok
  @callback get_room_thread_parents(Room.id(), Keyword.t()) :: [Room.event_id()]

  @database_backend Application.compile_env!(:radio_beam, [RadioBeam.Room.Database, :backend])
  defdelegate upsert_room(room), to: @database_backend
  defdelegate fetch_room(room_id), to: @database_backend
  defdelegate upsert_related_events(room_id, related_events), to: @database_backend
  defdelegate fetch_related_events(room_id), to: @database_backend
  defdelegate fetch_room_id_by_alias(alias), to: @database_backend
  defdelegate rebind_aliases(from_room_id, to_room_id), to: @database_backend
  defdelegate upsert_room_timeline_stream_pointer(room_id, stream_number, event_id), to: @database_backend
  defdelegate stream_room_timeline(room_id, opts), to: @database_backend
  defdelegate upsert_room_timestamp_pointer(room_id, timestamp, event_id), to: @database_backend
  defdelegate stream_room_event_ids_from_timestamp(room_id, timestamp, direction), to: @database_backend
  defdelegate stream_room_event_ids_from_timestamp(room_id, timestamp, direction, opts), to: @database_backend
  defdelegate upsert_room_thread_parent(room_id, stream_number, event_id), to: @database_backend
  defdelegate get_room_thread_parents(room_id, opts), to: @database_backend

  def create_alias(alias, room_id, ensure_room_exists?) do
    if Enum.any?(RadioBeam.local_homeservers(), &(&1.server_display_name == alias.server_name)) do
      @database_backend.create_alias(alias, room_id, ensure_room_exists?)
    else
      {:error, :invalid_or_unknown_server_name}
    end
  end
end
