defmodule RadioBeamWeb.SyncControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Device
  alias RadioBeam.User
  alias RadioBeam.Room.Timeline.Filter
  alias RadioBeam.Room

  setup %{conn: conn} do
    user1 = Fixtures.user()
    user2 = Fixtures.user()
    device = Fixtures.device(user1.id, "da steam deck")

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"),
      user: user1,
      creator: user2,
      device: device
    }
  end

  describe "sync/2" do
    test "successfully syncs with a room", %{conn: conn, creator: creator, user: user, device: device} do
      conn = get(conn, ~p"/_matrix/client/v3/sync", %{})

      assert %{"account_data" => account_data, "rooms" => rooms, "next_batch" => since} = json_response(conn, 200)
      for {_room_type, sync_update} <- rooms, do: assert(0 = map_size(sync_update))

      assert 0 = map_size(account_data)

      # ---

      {:ok, room_id1} = Room.create(creator, name: "name one")
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      :ok = User.put_account_data(user.id, :global, "m.some_config", %{"hello" => "world"})
      :ok = User.put_account_data(user.id, room_id1, "m.some_config", %{"hello" => "room"})
      message = Device.Message.new(%{"hello" => "world"}, "@hello:world", "com.spectrum.corncobtv.new_release")
      Device.Message.put(user.id, device.id, message)

      conn = get(conn, ~p"/_matrix/client/v3/sync?since=#{since}", %{})

      assert %{
               "account_data" => account_data,
               "to_device" => [%{"hello" => "world"}],
               "rooms" => %{
                 "join" => join_map,
                 "invite" => %{^room_id1 => %{"invite_state" => %{"events" => invite_state}}},
                 "leave" => leave_map
               },
               "next_batch" => since
             } = json_response(conn, 200)

      assert 0 = map_size(join_map)
      assert 0 = map_size(leave_map)

      user_id = user.id

      assert 4 = length(invite_state)
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.name"}, &1))
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.member", "state_key" => ^user_id}, &1))

      assert 1 = map_size(account_data)
      assert %{"m.some_config" => %{"hello" => "world"}} = account_data

      # ---

      {:ok, _event_id} = Room.join(room_id1, user.id)
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "yo")

      Device.Message.put(user.id, device.id, message)
      message = Device.Message.new(%{"hello2" => "world"}, "@hello:world", "com.spectrum.corncobtv.notification")
      Device.Message.put(user.id, device.id, message)

      {:ok, filter} = Jason.encode(%{"room" => %{"timeline" => %{"limit" => 2}}})

      conn = get(conn, ~p"/_matrix/client/v3/sync?since=#{since}&filter=#{filter}", %{})

      assert %{
               "account_data" => account_data,
               "to_device" => [%{"hello" => "world"}, %{"hello2" => "world"}],
               "rooms" => %{
                 "join" => %{^room_id1 => %{"account_data" => room_account_data, "state" => [], "timeline" => timeline}},
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

      assert %{"m.some_config" => %{"hello" => "world"}} = account_data
      assert %{"m.some_config" => %{"hello" => "room"}} = room_account_data
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

      assert %{"chunk" => chunk, "end" => next, "start" => "batch:" <> _, "state" => state} =
               json_response(conn, 200)

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
end
