defmodule RadioBeamWeb.RoomControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.Room
  alias RadioBeam.User.Auth

  setup %{conn: conn} do
    {user1, device} = Fixtures.device(Fixtures.user(), "da steam deck")
    %{access_token: token} = Auth.session_info(user1, device)

    %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user1}
  end

  describe "create/2" do
    test "successfully creates a room with the spec's example req body", %{conn: conn} do
      req_body = %{
        "creation_content" => %{
          "m.federate" => false
        },
        "name" => "The Grand Duke Pub",
        "preset" => "public_chat",
        "room_alias_name" => "thepub",
        "topic" => "All about happy hour"
      }

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)

      assert %{"room_id" => "!" <> _ = _room_id} = json_response(conn, 200)
    end

    test "successfully creates a room with all options specified", %{conn: conn} do
      server_name = RadioBeam.server_name()

      version = "10"

      req_body = %{
        "creation_content" => %{
          "m.federate" => false
        },
        "initial_state" => [
          %{
            "type" => "m.room.join_rules",
            "state_key" => "",
            "content" => %{"join_rule" => "public"}
          }
        ],
        "invite" => ["@bwyatt:#{server_name}"],
        # TODO
        "invite_3pid" => [],
        "is_direct" => false,
        "name" => "Club Aqua",
        "power_level_content_override" => %{"ban" => 124, "kick" => 123},
        "preset" => "trusted_private_chat",
        "room_alias_name" => "aqua",
        "room_version" => version,
        "topic" => "Club aqua? You get in there?",
        "visibility" => "public"
      }

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)

      assert %{"room_id" => _room_id} = json_response(conn, 200)
    end

    @tag :capture_log
    test "errors with M_ROOM_IN_USE when the supplied alias is already in use", %{conn: conn} do
      req_body = %{
        "name" => "Haunted House",
        "preset" => "public_chat",
        "room_alias_name" => "club_haunted_house",
        "topic" => "We don't have a trap door"
      }

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)

      assert %{"room_id" => _room_id} = json_response(conn, 200)

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)

      assert %{"errcode" => "M_ROOM_IN_USE"} = json_response(conn, 400)
    end

    @tag :capture_log
    test "errors with M_INVALID_ROOM_STATE when the power_levels don't make sense", %{conn: conn} do
      req_body = %{
        "name" => "A room",
        "preset" => "public_chat",
        "topic" => "It's just a room",
        # creator defaults to 100, couldn't set room name if required PL is 101
        "power_level_content_override" => %{"events" => %{"m.room.name" => 101}}
      }

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)

      assert %{"errcode" => "M_INVALID_ROOM_STATE"} = json_response(conn, 400)
    end

    test "errors with M_UNSUPPORTED_ROOM_VERSION when...well do I need to say more?", %{
      conn: conn
    } do
      req_body = %{
        "name" => "A room",
        "preset" => "public_chat",
        "topic" => "It's just a room",
        "room_version" => "lmao"
      }

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)

      assert %{"errcode" => "M_UNSUPPORTED_ROOM_VERSION"} = json_response(conn, 400)
    end
  end

  describe "joined/2" do
    test "returns a list of rooms the user is joined to", %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      conn = put_req_header(conn, "authorization", "Bearer #{token}")

      conn = get(conn, ~p"/_matrix/client/v3/joined_rooms", %{})

      assert %{"joined_rooms" => []} = json_response(conn, 200)

      req_body = %{
        "name" => "A room",
        "preset" => "public_chat",
        "topic" => "It's just a room"
      }

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)
      assert %{"room_id" => room_id} = json_response(conn, 200)

      :pong = Room.Server.ping(room_id)

      conn = get(conn, ~p"/_matrix/client/v3/joined_rooms", %{})

      assert %{"joined_rooms" => [^room_id]} = json_response(conn, 200)
    end
  end

  describe "invite/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())

      {:ok, room_id} = Room.create(user, power_levels: %{"invite" => 5})
      %{access_token: token} = Auth.session_info(user, device)

      %{
        conn: put_req_header(conn, "authorization", "Bearer #{token}"),
        user: user,
        room_id: room_id
      }
    end

    test "successfully invites a user", %{conn: conn, room_id: room_id} do
      invitee_id = "@letmeinpls:localhost"

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/invite", %{
          "user_id" => invitee_id,
          "reason" => "join us :)"
        })

      assert %{} = json_response(conn, 200)
    end

    test "rejects if inviter isn't in the room", %{conn: conn} do
      user = Fixtures.user("@aintevenhere:localhost")
      {:ok, room_id} = Room.create(user)

      invitee_id = "@lmao:localhost"

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/invite", %{
          "user_id" => invitee_id,
          "reason" => "join us :)"
        })

      assert %{"errcode" => "M_FORBIDDEN", "error" => error_message} = json_response(conn, 403)
      assert error_message =~ "aren't in the room"
    end

    test "rejects if inviter is in the room but does not have permission to invite", %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())

      {:ok, room_id} = Room.create(user, power_levels: %{"invite" => 101})

      invitee_id = "@lmao:localhost"
      %{access_token: token} = Auth.session_info(user, device)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/_matrix/client/v3/rooms/#{room_id}/invite", %{
          "user_id" => invitee_id,
          "reason" => "join us :)"
        })

      assert %{"errcode" => "M_FORBIDDEN", "error" => error_message} = json_response(conn, 403)
      assert error_message =~ "permission to invite others"
    end

    test "notifies when the room doesn't exist", %{conn: conn} do
      invitee_id = "@lmao:localhost"

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/!idontexist:localhost/invite", %{
          "user_id" => invitee_id,
          "reason" => "join us :)"
        })

      assert %{"errcode" => "M_NOT_FOUND", "error" => error_message} = json_response(conn, 404)
      assert error_message =~ "Room not found"
    end
  end

  describe "join/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "successfully joins the invited sender to a room", %{conn: conn, user: user} do
      creator = Fixtures.user("@calicocutpantsenjoyer:#{RadioBeam.server_name()}")

      {:ok, room_id} = Room.create(creator, preset: :private_chat)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/join", %{"reason" => "you gotta give"})

      assert %{"room_id" => ^room_id} = json_response(conn, 200)
    end

    test "fails to joins an invite-only room without an invite", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator, preset: :private_chat)

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/join", %{"reason" => "you gotta give"})

      assert %{"errcode" => "M_FORBIDDEN", "error" => error_message} = json_response(conn, 403)
      assert ^error_message = "You need to be invited by a member of this room to join"
    end

    test "successfully joins sender to a public room", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator, preset: :public_chat)

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/join", %{"reason" => "you gotta give"})

      assert %{"room_id" => ^room_id} = json_response(conn, 200)
    end

    test "successfully joins sender to a public room via an alias", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator, preset: :public_chat, alias: "glorp")

      conn =
        post(
          conn,
          ~p"/_matrix/client/v3/join/#{URI.encode("#glorp:#{RadioBeam.server_name()}")}",
          %{
            "reason" => "you gotta give"
          }
        )

      assert %{"room_id" => ^room_id} = json_response(conn, 200)
    end

    test "fails to join a room with an alias that can't be resolved", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, _room_id} = Room.create(creator, preset: :public_chat)

      conn =
        post(
          conn,
          ~p"/_matrix/client/v3/join/#{URI.encode("#glerp:#{RadioBeam.server_name()}")}",
          %{
            "reason" => "you gotta give"
          }
        )

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "successfully joins sender to a public room via the room ID", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator, preset: :public_chat)

      conn = post(conn, ~p"/_matrix/client/v3/join/#{room_id}", %{"reason" => "you gotta give"})

      assert %{"room_id" => ^room_id} = json_response(conn, 200)
    end
  end

  describe "leave/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "successfully leaves a room the sender has joined", %{conn: conn, user: user} do
      creator = Fixtures.user("@calicocutpantssupporter:#{RadioBeam.server_name()}")

      {:ok, room_id} = Room.create(creator, preset: :private_chat)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/leave", %{"reason" => "I didn't even ask to use it"})

      assert res = json_response(conn, 200)
      assert 0 = map_size(res)
    end

    test "fails to leave a room the user is not joined/invited to", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator)

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/leave", %{"reason" => "lol"})

      assert %{"errcode" => "M_FORBIDDEN", "error" => error_message} = json_response(conn, 403)
      assert ^error_message = "You need to be invited or joined to this room to leave"
    end

    test "successfully rejects an invite", %{conn: conn, user: user} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/leave", %{
          "reason" => "HEY HOLD THAT DOOR HOLD THAT DOOR"
        })

      assert res = json_response(conn, 200)
      assert 0 = map_size(res)
    end
  end

  describe "send/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "can send a message event to a room if authorized", %{conn: conn, user: creator} do
      {:ok, room_id} = Room.create(creator)

      content = %{"msgtype" => "m.text", "body" => "This is a test message"}
      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/12345", content)

      assert %{"event_id" => "$" <> _} = json_response(conn, 200)
    end

    test "rejects a message event if user is not in the room", %{conn: conn} do
      creator = Fixtures.user()
      {:ok, room_id} = Room.create(creator)

      content = %{"msgtype" => "m.text", "body" => "This is another test message"}
      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/22345", content)

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "rejects a message event if user does not have perms", %{conn: conn, user: user} do
      creator = Fixtures.user()

      {:ok, room_id} =
        Room.create(creator, power_levels: %{"events" => %{"m.room.message" => 80}})

      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      content = %{"msgtype" => "m.text", "body" => "This message should be rejected"}
      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/32345", content)

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "rejects a message event if request path does not have all required params", %{conn: conn, user: creator} do
      {:ok, room_id} = Room.create(creator)

      content = %{"msgtype" => "m.text", "body" => "This is another test message"}
      # missing txn ID
      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/send/m.room.message", content)

      assert %{"errcode" => "M_MISSING_PARAM"} = json_response(conn, 400)
    end

    test "rejects a message event if the provided msgtype is not known", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator)

      content = %{"msgtype" => "m.glorp", "body" => "This has a bad `msgtype`"}
      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/32345", content)

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 400)
      assert error =~ "msgtype needs to be one of"
    end

    test "rejects a duplicate annotation", %{conn: conn, user: creator} do
      {:ok, room_id} = Room.create(creator)

      {:ok, event_id} = Room.send_text_message(room_id, creator.id, "please react with 👍 to vote")
      rel = %{"m.relates_to" => %{"event_id" => event_id, "rel_type" => "m.annotation", "key" => "👍"}}
      {:ok, _} = Room.send(room_id, creator.id, "m.reaction", rel)

      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/send/m.reaction/32777", rel)

      assert %{"errcode" => "M_DUPLICATE_ANNOTATION", "error" => error} = json_response(conn, 400)
      assert error =~ "already reacted with that"
    end
  end

  describe "get_event/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "returns the event (200) with the requester is auth'd to view it", %{
      conn: conn,
      user: user
    } do
      content = %{"msgtype" => "m.text", "body" => "Hello new room"}
      {:ok, room_id} = Room.create(user)
      {:ok, event_id} = Room.send(room_id, user.id, "m.room.message", content)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/event/#{event_id}", %{})
      assert %{"event_id" => ^event_id} = json_response(conn, 200)
    end

    test "returns an M_FORBIDDEN (403) error when requester is not auth'd", %{conn: conn} do
      creator = Fixtures.user()
      {:ok, room_id} = Room.create(creator)

      content = %{
        "msgtype" => "m.text",
        "body" => "I sure hope nobody outside the room can read this, even if they know the event ID"
      }

      {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/event/#{event_id}", %{})
      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end

  describe "get_joined_members/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "returns an object of members IDs to profile info (200)", %{conn: conn, user: user} do
      {:ok, room_id} = Room.create(user)

      content = %{"msgtype" => "m.text", "body" => "hi hi hello"}
      {:ok, _event_id} = Room.send(room_id, user.id, "m.room.message", content)

      user2 = Fixtures.user()
      {:ok, _event_id} = Room.invite(room_id, user.id, user2.id)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/joined_members", %{})

      user_id = user.id
      assert %{"joined" => %{^user_id => %{}} = joined} = json_response(conn, 200)
      assert 1 = map_size(joined)

      {:ok, _event_id} = Room.join(room_id, user2.id)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/joined_members", %{})
      assert %{"joined" => joined} = json_response(conn, 200)
      assert 2 = map_size(joined)
    end

    test "returns M_FORBIDDEN (403) when the requester is not in the room", %{conn: conn} do
      user2 = Fixtures.user()
      {:ok, room_id} = Room.create(user2)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/joined_members", %{})
      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end

  describe "get_members/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "returns the members (200) when the requester is in the room", %{
      conn: conn,
      user: user
    } do
      {:ok, room_id} = Room.create(user)

      {:ok, event_id} = Room.send_text_message(room_id, user.id, "hi hi hello")

      pagination_token_string =
        room_id |> PaginationToken.new(event_id, :forward, System.os_time(:millisecond)) |> PaginationToken.encode()

      user2 = Fixtures.user()
      {:ok, _event_id} = Room.invite(room_id, user.id, user2.id)
      {:ok, _event_id} = Room.join(room_id, user2.id)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/members", %{"at" => pagination_token_string})

      assert %{"chunk" => chunk} = json_response(conn, 200)
      assert 1 = length(chunk)
    end

    test "returns the members (200) whose membership passes the filter", %{
      conn: conn,
      user: user
    } do
      {:ok, room_id} = Room.create(user)

      user2 = Fixtures.user()
      {:ok, _event_id} = Room.invite(room_id, user.id, user2.id)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/members", %{"membership" => "join"})

      assert %{"chunk" => chunk} = json_response(conn, 200)
      assert 1 = length(chunk)

      {:ok, _event_id} = Room.join(room_id, user2.id)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/members", %{"membership" => "join"})

      assert %{"chunk" => chunk} = json_response(conn, 200)
      assert 2 = length(chunk)
    end

    test "returns the members (200) at a specific event when the requester was in the room", %{
      conn: conn,
      user: user
    } do
      {:ok, room_id} = Room.create(user)

      :pong = Room.Server.ping(room_id)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/members", %{})
      user_id = user.id
      assert %{"chunk" => [%{"sender" => ^user_id} = membership_event]} = json_response(conn, 200)
      assert "join" = membership_event["content"]["membership"]
    end

    test "returns an M_FORBIDDEN (403) error when requester is not in the room", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/members", %{})
      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end

  describe "get_state/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "returns the state (200) when the requester is in the room", %{conn: conn, user: user} do
      {:ok, room_id} = Room.create(user)

      :pong = Room.Server.ping(room_id)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state", %{})
      assert state = json_response(conn, 200)
      assert 6 = length(state)
    end

    test "returns an M_FORBIDDEN (403) error when requester is not in the room", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state", %{})
      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end

  describe "put_state/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "puts the state event (200) when the requester is in the room and has permission to do so", %{
      conn: conn,
      user: user
    } do
      {:ok, room_id} = Room.create(user)

      conn =
        put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state/m.room.membership/#{user.id}", %{
          "membership" => "join",
          "displayname" => "glorpbot"
        })

      assert %{"event_id" => _} = json_response(conn, 200)
    end

    test "returns a state event content (200) with an empty state_key", %{conn: conn, user: user} do
      {:ok, room_id} = Room.create(user)

      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state/m.room.name/", %{"name" => "A Cool Room"})
      assert %{"event_id" => _} = json_response(conn, 200)
    end

    test "returns an M_FORBIDDEN (403) error when requester is not in the room", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator)

      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state/m.room.name/", %{"name" => "Not My Room"})
      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "returns an M_FORBIDDEN (403) error when the user does not have permission to set state events", %{
      conn: conn,
      user: user
    } do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator, power_levels: %{"state_default" => 100})
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state/m.room.name/", %{"name" => "Can't do this :("})
      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end

  describe "redact/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "returns the redaction event ID (200) when deleting own message w/ default power levels", %{
      conn: conn,
      user: user
    } do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      {:ok, event_id} = Room.send_text_message(room_id, user.id, "this was meant for another room")

      conn =
        put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/abcdf111df", %{
          "reason" => "oops wrong room"
        })

      assert %{"event_id" => "$" <> _} = json_response(conn, 200)
    end

    test "returns the redaction event ID (200) when someone w/out `redact` power level tries to redact another's event",
         %{
           conn: conn,
           user: user
         } do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      {:ok, event_id} =
        Room.send_text_message(room_id, creator.id, "I am the creator, a mere member cannot redact this")

      conn =
        put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/redact/#{event_id}/abcdf111df", %{
          "reason" => "imagine"
        })

      # note that this does not mean the redaction was actually applied, just
      # that the m.room.redaction event was allowed to be sent
      assert %{"event_id" => "$" <> _} = json_response(conn, 200)
    end
  end

  describe "get_state_event/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "returns the state event content (200) when the requester is in the room", %{conn: conn, user: user} do
      {:ok, room_id} = Room.create(user)

      :pong = Room.Server.ping(room_id)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state/m.room.member/#{user.id}", %{})
      assert %{"membership" => "join"} = json_response(conn, 200)
    end

    test "returns a state event content (200) with an empty state_key", %{conn: conn, user: user} do
      rv = "10"
      {:ok, room_id} = Room.create(user, version: rv)

      :pong = Room.Server.ping(room_id)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state/m.room.create/", %{})
      assert %{"room_version" => ^rv} = json_response(conn, 200)
    end

    test "returns an M_FORBIDDEN (403) error when requester is not in the room", %{conn: conn} do
      creator = Fixtures.user()

      {:ok, room_id} = Room.create(creator)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state/m.room.member/#{creator.id}", %{})
      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "returns an M_NOT_FOUND (404) error when the state does not contain the key", %{conn: conn, user: user} do
      {:ok, room_id} = Room.create(user)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/state/m.bathroom.member/#{user.id}", %{})
      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end
  end

  describe "get_nearest_event/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user())
      %{access_token: token} = Auth.session_info(user, device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}"), user: user}
    end

    test "returns a temporally suitable event (200)", %{conn: conn, user: user} do
      {:ok, room_id} = Room.create(user)
      {:ok, event_id} = Room.send_text_message(room_id, user.id, "heyo")

      query_params = %{dir: "b", ts: System.os_time(:millisecond)}

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/timestamp_to_event?#{query_params}", %{})
      assert %{"event_id" => ^event_id} = json_response(conn, 200)
    end

    test "returns an M_NOT_FOUND (404) error when there is not a temporally suitable event", %{conn: conn, user: user} do
      {:ok, room_id} = Room.create(user)

      Process.sleep(25)

      query_params = %{dir: "f", ts: :os.system_time(:millisecond)}

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/timestamp_to_event?#{query_params}", %{})
      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "returns an M_NOT_FOUND (404) error when the user is not in the room", %{conn: conn} do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)

      query_params = %{dir: "f", ts: :os.system_time(:millisecond)}

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/timestamp_to_event?#{query_params}", %{})
      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "returns an M_NOT_FOUND (404) error when the room doesn't exist", %{conn: conn} do
      query_params = %{dir: "b", ts: :os.system_time(:millisecond)}

      conn = get(conn, ~p"/_matrix/client/v3/rooms/!lmao:localhost/timestamp_to_event?#{query_params}", %{})
      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end
  end

  describe "put_typing/2" do
    test "returns an empty JSON object (200) when the typing status was accepted", %{
      conn: conn,
      user: %{id: user_id} = user
    } do
      {:ok, room_id} = Room.create(user)

      for typing <- ~w|true false|a do
        req_body = %{typing: typing, timeout: 5_000}
        conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/typing/#{user_id}", req_body)

        assert response = json_response(conn, 200)
        assert 0 = map_size(response)
      end
    end

    test "returns an M_NOT_FOUND (404) error when the room doesn't exist", %{conn: conn, user: %{id: user_id}} do
      req_body = %{typing: true, timeout: 5_000}
      conn = put(conn, ~p"/_matrix/client/v3/rooms/!lmaoooo12312:localhost/typing/#{user_id}", req_body)

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end
  end
end
