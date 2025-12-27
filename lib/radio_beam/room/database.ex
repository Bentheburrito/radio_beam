defmodule RadioBeam.Room.Database do
  @moduledoc """
  A behaviour for implementing a persistence backend for the `RadioBeam.Room`
  bounded context.
  """
  alias RadioBeam.Room
  alias RadioBeam.Room.View

  @type ensure_room_exists?() :: boolean()

  @callback upsert_room(Room.t()) :: :ok
  @callback fetch_room(Room.id()) :: {:ok, Room.t()} | {:error, :not_found}
  @callback upsert_view(View.key(), View.t()) :: :ok
  @callback fetch_view(View.key()) :: {:ok, View.t()} | {:error, :not_found}
  @callback create_alias(Room.Alias.t(), Room.id(), ensure_room_exists?()) ::
              :ok | {:error, :alias_in_use | :room_does_not_exist}
  @callback fetch_room_id_by_alias(Room.Alias.t()) :: {:ok, Room.t()} | {:error, :not_found}

  @database_backend Application.compile_env!(:radio_beam, [RadioBeam.Room.Database, :backend])
  defdelegate upsert_room(room), to: @database_backend
  defdelegate fetch_room(room_id), to: @database_backend
  defdelegate upsert_view(key, view), to: @database_backend
  defdelegate fetch_view(view_key), to: @database_backend
  defdelegate fetch_room_id_by_alias(alias), to: @database_backend

  def create_alias(alias, room_id, ensure_room_exists? \\ true) do
    if alias.server_name != RadioBeam.Config.server_name() do
      {:error, :invalid_or_unknown_server_name}
    else
      @database_backend.create_alias(alias, room_id, ensure_room_exists?)
    end
  end
end
