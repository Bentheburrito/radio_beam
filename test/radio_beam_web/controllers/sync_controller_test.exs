defmodule RadioBeamWeb.SyncControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.Device
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.User

  setup %{conn: conn} do
    {:ok, user1} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
    Repo.insert(user1)

    {:ok, user2} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
    Repo.insert(user2)

    {:ok, device} =
      Device.new(%{
        id: Device.generate_token(),
        user_id: user1.id,
        display_name: "da steam deck",
        access_token: Device.generate_token(),
        refresh_token: Device.generate_token()
      })

    Repo.insert(device)

    %{conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"), user: user1, creator: user2}
  end

  describe "sync/2" do
    test "successfully syncs with a room", %{conn: conn, creator: creator, user: user} do
      conn = get(conn, ~p"/_matrix/client/v3/sync", %{})

      assert %{"rooms" => rooms, "next_batch" => since} = json_response(conn, 200)
      for {_room_type, sync_update} <- rooms, do: assert(0 = map_size(sync_update))

      # ---

      {:ok, room_id1} = Room.create("5", creator, %{}, name: "name one")
      :ok = Room.invite(room_id1, creator.id, user.id)

      conn = get(conn, ~p"/_matrix/client/v3/sync?since=#{since}", %{})

      assert %{
               "rooms" => %{
                 "join" => join_map,
                 "invite" => %{^room_id1 => %{"invite_state" => %{"events" => invite_state}}},
                 "leave" => leave_map
               },
               "next_batch" => since
             } = json_response(conn, 200)

      assert 0 = map_size(join_map)
      assert 0 = map_size(leave_map)

      assert 3 = length(invite_state)
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.name"}, &1))

      # ---

      :ok = Room.join(room_id1, user.id)
      :ok = Room.set_name(room_id1, creator.id, "yo")

      conn = get(conn, ~p"/_matrix/client/v3/sync?since=#{since}", %{})

      assert %{
               "rooms" => %{
                 "join" => %{^room_id1 => %{"state" => state, "timeline" => timeline}},
                 "invite" => invite_map,
                 "leave" => leave_map
               },
               "next_batch" => _since
             } = json_response(conn, 200)

      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      assert 8 = length(state)

      user_id = user.id

      assert %{
               "limited" => false,
               "events" => [
                 %{"type" => "m.room.member", "content" => %{"membership" => "join"}, "sender" => ^user_id},
                 %{"type" => "m.room.name", "content" => %{"name" => "yo"}}
               ]
             } =
               timeline
    end
  end
end
