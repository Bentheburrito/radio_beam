defmodule RadioBeamWeb.SyncControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Room.Timeline.Filter
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

      {:ok, room_id1} = Room.create(creator, name: "name one")
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)

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

      {:ok, _event_id} = Room.join(room_id1, user.id)
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "yo")

      conn = get(conn, ~p"/_matrix/client/v3/sync?since=#{since}", %{})

      assert %{
               "rooms" => %{
                 "join" => %{^room_id1 => %{"state" => [], "timeline" => timeline}},
                 "invite" => invite_map,
                 "leave" => leave_map
               },
               "next_batch" => _since
             } = json_response(conn, 200)

      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

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

  describe "get_messages/2" do
    test "successfully fetches events when user is a member of the room", %{conn: conn, user: creator} do
      {:ok, room_id} = Room.create(creator, name: "This is a cool room")

      {:ok, _event_id} =
        Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "this place is so cool"})

      filter = %{"room" => %{"timeline" => %{"limit" => 3}}}
      {:ok, filter_id} = Filter.put(creator.id, filter)

      query_params = %{
        filter: filter_id,
        dir: "b"
      }

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/messages?#{query_params}", %{})

      assert %{"chunk" => chunk, "end" => next, "start" => "last", "state" => state} = json_response(conn, 200)
      assert 1 = length(state)
      assert [%{"content" => %{"body" => "this place is so cool"}}, %{"type" => "m.room.name"}, _] = chunk

      query_params = %{
        filter: filter_id,
        dir: "b",
        from: next
      }

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/messages?#{query_params}", %{})

      assert %{"chunk" => chunk, "end" => _next2, "start" => ^next, "state" => state} = json_response(conn, 200)
      assert 1 = length(state)
      assert [%{"type" => "m.room.history_visibility"}, %{"type" => "m.room.join_rules"}, _] = chunk
    end
  end

  test "fails with M_FORBIDDEN (403) when the room doesn't exist or the requester isn't currently in it", %{
    conn: conn,
    creator: creator
  } do
    {:ok, room_id} = Room.create(creator, name: "This is a cool room")

    query_params = %{
      dir: "b"
    }

    conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/messages?#{query_params}", %{})

    assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
  end
end
