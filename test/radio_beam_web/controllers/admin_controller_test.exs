defmodule RadioBeamWeb.AdminControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Room

  describe "report_room/2" do
    test "saves the report and returns an empty JSON object (200)", %{conn: conn} do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)

      conn = post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/report", %{"reason" => "not moderated, full of spam"})
      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns M_NOT_FOUND (404) when the room doesn't exist", %{conn: conn} do
      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/!idontexist12312312/report", %{
          "reason" => "not moderated, full of spam (I'm lying)"
        })

      assert %{"errcode" => "M_NOT_FOUND", "error" => "Room not found"} = json_response(conn, 404)
    end

    test "returns M_FORBIDDEN (403) when the user has already an outstanding report for the room", %{conn: conn} do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)

      conn = post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/report", %{"reason" => "not moderated, full of spam"})
      conn = post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/report", %{"reason" => "full of spam! pls help"})
      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "already reported"
    end
  end

  describe "report_room_event/2" do
    test "saves the report and returns an empty JSON object (200)", %{conn: conn, account: %{user_id: reporter_id}} do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      {:ok, _} = Room.invite(room_id, creator_id, reporter_id)
      {:ok, _} = Room.join(room_id, reporter_id)

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "blahblahblahblahblahblahblah")

      conn = post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/report/#{event_id}", %{"reason" => "spam"})
      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns M_NOT_FOUND (404) when the event doesn't exist", %{conn: conn, account: %{user_id: reporter_id}} do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      {:ok, _} = Room.invite(room_id, creator_id, reporter_id)
      {:ok, _} = Room.join(room_id, reporter_id)

      conn = post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/report/$asdfasdf", %{"reason" => "spam (I'm lying)"})

      assert %{"errcode" => "M_NOT_FOUND", "error" => error} = json_response(conn, 404)
      assert error =~ "event was not found"
    end

    test "returns M_NOT_FOUND (404) when the event exists, but the user isn't a member of the room", %{
      conn: conn,
      account: %{user_id: reporter_id}
    } do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      {:ok, _} = Room.invite(room_id, creator_id, reporter_id)
      # didn't accept invite

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "blahblahblahblahblahblahblah")

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/report/#{event_id}", %{"reason" => "spam (how would I know?)"})

      assert %{"errcode" => "M_NOT_FOUND", "error" => error} = json_response(conn, 404)
      assert error =~ "event was not found"
    end

    test "returns M_FORBIDDEN (403) when the user has already an outstanding report for the event", %{
      conn: conn,
      account: %{user_id: reporter_id}
    } do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      {:ok, _} = Room.invite(room_id, creator_id, reporter_id)
      {:ok, _} = Room.join(room_id, reporter_id)

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "blahblahblahblahblahblahblah")

      conn = post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/report/#{event_id}", %{"reason" => "spam"})
      conn = post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/report/#{event_id}", %{"reason" => "delete pls!!"})
      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "already reported"
    end
  end

  describe "report_user/2" do
    test "saves the report and returns an empty JSON object (200)", %{conn: conn} do
      %{user_id: user_id} = Fixtures.create_account()

      conn = post(conn, ~p"/_matrix/client/v3/users/#{user_id}/report", %{"reason" => "they were mean to me"})
      assert response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns M_NOT_FOUND (404) when the event doesn't exist", %{conn: conn} do
      conn =
        post(conn, ~p"/_matrix/client/v3/users/@helloidontexistt/report", %{
          "reason" => "they were mean to me (I talk to ghosts)"
        })

      assert %{"errcode" => "M_NOT_FOUND", "error" => "User not found"} = json_response(conn, 404)
    end

    test "returns M_FORBIDDEN (403) when the user has already an outstanding report for the user", %{conn: conn} do
      %{user_id: user_id} = Fixtures.create_account()

      conn = post(conn, ~p"/_matrix/client/v3/users/#{user_id}/report", %{"reason" => "they were mean to me"})
      conn = post(conn, ~p"/_matrix/client/v3/users/#{user_id}/report", %{"reason" => "they were mean to me"})
      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "already reported"
    end
  end

  describe "whois/2" do
    setup do
      device_display_name = "My Awesome Computer"

      %{conn: random_user_conn, account: %{user_id: random_id}} =
        RadioBeamWeb.ConnCase.setup_authenticated_user(Phoenix.ConnTest.build_conn(), %{
          device_display_name: device_display_name
        })

      # just doing this so the "last_seen_from_ip" field gets set
      get(random_user_conn, ~p"/_matrix/client/v3/capabilities", %{})

      %{device_display_name: device_display_name, random_id: random_id}
    end

    test "queries a user if the requester is an admin", %{
      conn: conn,
      account: %{user_id: admin_id},
      device_display_name: device_display_name,
      random_id: random_id
    } do
      current_admins = RadioBeam.admins()
      Application.put_env(:radio_beam, :admins, [admin_id | current_admins])

      conn = get(conn, ~p"/_matrix/client/v3/admin/whois/#{random_id}", %{})

      assert %{"user_id" => ^random_id, "devices" => devices} = json_response(conn, 200)

      assert %{
               ^device_display_name => %{
                 "sessions" => [
                   %{"connections" => [%{"ip" => "127.0.0.1", "last_seen" => _, "user_agent" => "unknown"}]}
                 ]
               }
             } = devices
    end

    test "returns M_NOT_FOUND if a user does not exist and the requester is an admin", %{
      conn: conn,
      account: %{user_id: admin_id}
    } do
      non_existing_user_id = Fixtures.user_id()

      current_admins = RadioBeam.admins()
      Application.put_env(:radio_beam, :admins, [admin_id | current_admins])

      conn = get(conn, ~p"/_matrix/client/v3/admin/whois/#{non_existing_user_id}", %{})

      assert %{"errcode" => "M_NOT_FOUND", "error" => error} = json_response(conn, 404)
      assert error =~ "user not found, or you don't have permission"
    end

    test "returns M_NOT_FOUND (404) if the requester is not an admin", %{conn: conn, random_id: random_id} do
      conn = get(conn, ~p"/_matrix/client/v3/admin/whois/#{random_id}", %{})

      assert %{"errcode" => "M_NOT_FOUND", "error" => error} = json_response(conn, 404)
      assert error =~ "user not found, or you don't have permission"
    end
  end
end
