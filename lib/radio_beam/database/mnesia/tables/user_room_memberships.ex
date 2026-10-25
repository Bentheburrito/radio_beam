defmodule RadioBeam.Database.Mnesia.Tables.UserRoomMemberships do
  @moduledoc false

  alias RadioBeam.User

  require Record
  Record.defrecord(:user_room_memberships, __MODULE__, user_id: nil, room_ids_to_membership: nil)

  @type t() ::
          record(:user_room_memberships,
            user_id: User.id(),
            room_ids_to_membership: %{RadioBeam.Room.id() => String.t()}
          )

  def opts,
    do: [attributes: user_room_memberships() |> user_room_memberships() |> Keyword.keys(), type: :set, index: []]
end
