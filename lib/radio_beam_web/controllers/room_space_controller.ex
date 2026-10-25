defmodule RadioBeamWeb.RoomSpaceController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 4]

  alias RadioBeam.Room

  @forbidden_errors ~w|not_found unauthorized|a
  @forbidden_msg "Room does not exist, or you lack permission to view it"
  def hierarchy(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.user_id

    case Room.get_hierarchy(room_id, user_id) do
      {:ok, room_descriptions} -> json(conn, %{rooms: room_descriptions})
      {:error, error} when error in @forbidden_errors -> json_error(conn, 403, :forbidden, @forbidden_msg)
    end
  end
end
