defmodule RadioBeamWeb.Schemas.RoomKeys do
  @moduledoc false

  import RadioBeamWeb.Schemas, only: [room_id: 1]

  alias Polyjuice.Util.Schema

  def put_keys, do: Schema.any_of([room_session_info(), session_info(), key_backup_data()])

  defp room_session_info, do: %{"rooms" => Schema.object_with_entries(&room_id/1, session_info())}

  defp session_info, do: %{"sessions" => Schema.object_with_entries(:string, key_backup_data())}

  defp key_backup_data do
    %{
      "first_message_index" => :integer,
      "forwarded_count" => :integer,
      "is_verified" => :boolean,
      "session_data" => %{}
    }
  end

  def create_backup do
    %{
      "algorithm" => Schema.enum(RadioBeam.User.RoomKeys.allowed_algorithms()),
      "auth_data" => Schema.object_with_entries(:any, :any)
    }
  end

  def put_backup_auth_data, do: Map.put(create_backup(), "version", [:string, :optional])
end
