defmodule RadioBeamWeb.RoomControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.RoomRegistry
  alias RadioBeam.Device
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.RoomAlias
  alias RadioBeam.User

  setup %{conn: conn} do
    {:ok, user1} = User.new("@lknope:#{RadioBeam.server_name()}", "b1gSTR@NGpwD")
    Repo.insert(user1)

    {:ok, user2} = User.new("@bwyatt:#{RadioBeam.server_name()}", "4notherSTR@NGpwD")
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

    %{conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}")}
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

      assert %{"room_id" => room_id} = json_response(conn, 200)
      assert [{_pid, _}] = Registry.lookup(RoomRegistry, room_id)
    end

    test "successfully creates a room with all options specified", %{conn: conn} do
      server_name = RadioBeam.server_name()

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
        "power_level_content_override" => %{"ban" => 124, "kick" => "123"},
        "preset" => "trusted_private_chat",
        "room_alias_name" => "aqua",
        "room_version" => "4",
        "topic" => "Club aqua? You get in there?",
        "visibility" => "public"
      }

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)

      assert %{"room_id" => room_id} = json_response(conn, 200)
      assert [{_pid, _}] = Registry.lookup(RoomRegistry, room_id)

      assert {:ok, %Room{id: ^room_id, version: "4", state: state}} = Repo.get(Room, room_id)

      assert %{"join_rule" => "public"} = get_in(state, [{"m.room.join_rules", ""}, "content"])

      alias = "#aqua:#{server_name}"
      assert %{"alias" => ^alias} = get_in(state, [{"m.room.canonical_alias", ""}, "content"])
      assert {:ok, %RoomAlias{alias: ^alias, room_id: ^room_id}} = Repo.get(RoomAlias, alias)

      assert %{"membership" => "invite"} =
               get_in(state, [{"m.room.member", "@bwyatt:#{server_name}"}, "content"])
    end

    test "errors with M_ROOM_IN_USE when the supplied alias is already in use", %{conn: conn} do
      req_body = %{
        "name" => "Haunted House",
        "preset" => "public_chat",
        "room_alias_name" => "club_haunted_house",
        "topic" => "We don't have a trap door"
      }

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)

      assert %{"room_id" => room_id} = json_response(conn, 200)
      assert [{_pid, _}] = Registry.lookup(RoomRegistry, room_id)

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)

      assert %{"errcode" => "M_ROOM_IN_USE"} = json_response(conn, 400)
    end

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
      {:ok, user} = User.new("@thaverford:#{RadioBeam.server_name()}", "4STR@NGpwD")
      Repo.insert(user)

      {:ok, device} =
        Device.new(%{
          id: Device.generate_token(),
          user_id: user.id,
          display_name: "da steam deck",
          access_token: Device.generate_token(),
          refresh_token: Device.generate_token()
        })

      Repo.insert(device)

      conn = put_req_header(conn, "authorization", "Bearer #{device.access_token}")

      conn = get(conn, ~p"/_matrix/client/v3/joined_rooms", %{})

      assert %{"joined_rooms" => []} = json_response(conn, 200)

      req_body = %{
        "name" => "A room",
        "preset" => "public_chat",
        "topic" => "It's just a room"
      }

      conn = post(conn, ~p"/_matrix/client/v3/createRoom", req_body)
      assert %{"room_id" => room_id} = json_response(conn, 200)

      conn = get(conn, ~p"/_matrix/client/v3/joined_rooms", %{})

      assert %{"joined_rooms" => [^room_id]} = json_response(conn, 200)
    end
  end

  describe "invite/2" do
    setup %{conn: conn} do
      {:ok, user} = User.new("@randomuser:#{RadioBeam.server_name()}", "4STR@NGpwD")
      Repo.insert(user)

      {:ok, device} =
        Device.new(%{
          id: Device.generate_token(),
          user_id: user.id,
          display_name: "da steam deck",
          access_token: Device.generate_token(),
          refresh_token: Device.generate_token()
        })

      Repo.insert(device)

      {:ok, room_id} = Room.create(user, power_levels: %{"invite" => 5})

      %{
        conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"),
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
      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      assert "invite" = get_in(state, [{"m.room.member", invitee_id}, "content", "membership"])
      assert "join us :)" = get_in(state, [{"m.room.member", invitee_id}, "content", "reason"])
    end

    test "rejects if inviter isn't in the room", %{conn: conn} do
      user_id = "@aintevenhere:localhost"
      {:ok, user} = User.new(user_id, "4STR@NGpwD")
      Repo.insert(user)
      {:ok, room_id} = Room.create(user)

      invitee_id = "@lmao:localhost"

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/invite", %{
          "user_id" => invitee_id,
          "reason" => "join us :)"
        })

      assert %{"errcode" => "M_FORBIDDEN", "error" => error_message} = json_response(conn, 403)
      assert error_message =~ "aren't in the room"
      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      refute is_map_key(state, {"m.room.member", invitee_id})
    end

    test "rejects if inviter is in the room but does not have permission to invite", %{conn: conn} do
      {:ok, user} = User.new("@areallycooluser:#{RadioBeam.server_name()}", "4STR@NGpwD")
      Repo.insert(user)

      {:ok, device} =
        Device.new(%{
          id: Device.generate_token(),
          user_id: user.id,
          display_name: "da steam deck",
          access_token: Device.generate_token(),
          refresh_token: Device.generate_token()
        })

      Repo.insert(device)

      {:ok, room_id} = Room.create(user, power_levels: %{"invite" => 101})

      invitee_id = "@lmao:localhost"

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{device.access_token}")
        |> post(~p"/_matrix/client/v3/rooms/#{room_id}/invite", %{
          "user_id" => invitee_id,
          "reason" => "join us :)"
        })

      assert %{"errcode" => "M_FORBIDDEN", "error" => error_message} = json_response(conn, 403)
      assert error_message =~ "permission to invite others"
      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      refute is_map_key(state, {"m.room.member", invitee_id})
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
      {:ok, user} = User.new("@ghostofxmasfuture:#{RadioBeam.server_name()}", "4STR@NGpwD")
      Repo.insert(user)

      {:ok, device} =
        Device.new(%{
          id: Device.generate_token(),
          user_id: user.id,
          display_name: "da steam deck",
          access_token: Device.generate_token(),
          refresh_token: Device.generate_token()
        })

      Repo.insert(device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"), user: user}
    end

    test "successfully joins the invited sender to a room", %{conn: conn, user: user} do
      {:ok, creator} = User.new("@calicocutpantsenjoyer:#{RadioBeam.server_name()}", "4STR@NGpwD")
      Repo.insert(creator)

      {:ok, room_id} = Room.create(creator, preset: :private_chat)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/join", %{"reason" => "you gotta give"})

      assert %{"room_id" => ^room_id} = json_response(conn, 200)
      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      assert "you gotta give" = get_in(state, [{"m.room.member", user.id}, "content", "reason"])
    end

    test "fails to joins an invite-only room without an invite", %{conn: conn} do
      {:ok, creator} = User.new("@calicocutpantsenjoyer:#{RadioBeam.server_name()}", "4STR@NGpwD")
      Repo.insert(creator)

      {:ok, room_id} = Room.create(creator, preset: :private_chat)

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/join", %{"reason" => "you gotta give"})

      assert %{"errcode" => "M_FORBIDDEN", "error" => error_message} = json_response(conn, 403)
      assert ^error_message = "You need to be invited by a member of this room to join"
    end

    test "successfully joins sender to a public room", %{conn: conn} do
      {:ok, creator} = User.new("@calicocutpantsenjoyer:#{RadioBeam.server_name()}", "4STR@NGpwD")
      Repo.insert(creator)

      {:ok, room_id} = Room.create(creator, preset: :public_chat)

      conn =
        post(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/join", %{"reason" => "you gotta give"})

      assert %{"room_id" => ^room_id} = json_response(conn, 200)
    end

    test "successfully joins sender to a public room via an alias", %{conn: conn} do
      {:ok, creator} = User.new("@calicocutpantsenjoyer:#{RadioBeam.server_name()}", "4STR@NGpwD")
      Repo.insert(creator)

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
      {:ok, creator} = User.new("@calicocutpantsenjoyer:#{RadioBeam.server_name()}", "4STR@NGpwD")
      Repo.insert(creator)

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
  end

  describe "send/2" do
    setup %{conn: conn} do
      {:ok, user} =
        "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")

      Repo.insert(user)

      {:ok, device} =
        Device.new(%{
          id: Device.generate_token(),
          user_id: user.id,
          display_name: "da steam deck",
          access_token: Device.generate_token(),
          refresh_token: Device.generate_token()
        })

      Repo.insert(device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"), user: user}
    end

    test "can send a message event to a room if authorized", %{conn: conn, user: creator} do
      {:ok, room_id} = Room.create(creator)

      content = %{"msgtype" => "m.text", "body" => "This is a test message"}
      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/12345", content)

      assert %{"event_id" => "!" <> _} = json_response(conn, 200)
    end

    test "rejects a message event if user is not in the room", %{conn: conn} do
      {:ok, creator} =
        "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")

      Repo.insert(creator)
      {:ok, room_id} = Room.create(creator)

      content = %{"msgtype" => "m.text", "body" => "This is another test message"}
      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/22345", content)

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "rejects a message event if user does not have perms", %{conn: conn, user: user} do
      {:ok, creator} =
        "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")

      Repo.insert(creator)

      {:ok, room_id} =
        Room.create(creator, power_levels: %{"events" => %{"m.room.message" => 80}})

      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      content = %{"msgtype" => "m.text", "body" => "This message should be rejected"}
      conn = put(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/send/m.room.message/32345", content)

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end

  describe "get_event/2" do
    setup %{conn: conn} do
      {:ok, user} =
        "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")

      Repo.insert(user)

      {:ok, device} =
        Device.new(%{
          id: Device.generate_token(),
          user_id: user.id,
          display_name: "da steam deck",
          access_token: Device.generate_token(),
          refresh_token: Device.generate_token()
        })

      Repo.insert(device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"), user: user}
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
      {:ok, creator} =
        "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")

      Repo.insert(creator)
      {:ok, room_id} = Room.create(creator)

      content = %{
        "msgtype" => "m.text",
        "body" =>
          "I sure hope nobody outside the room can read this, even if they know the event ID"
      }

      {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/event/#{event_id}", %{})
      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end

  describe "get_members/2" do
    setup %{conn: conn} do
      {:ok, user} =
        "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")

      Repo.insert(user)

      {:ok, device} =
        Device.new(%{
          id: Device.generate_token(),
          user_id: user.id,
          display_name: "da steam deck",
          access_token: Device.generate_token(),
          refresh_token: Device.generate_token()
        })

      Repo.insert(device)

      %{conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"), user: user}
    end

    test "returns the members (200) with the requester in the room", %{
      conn: conn,
      user: user
    } do
      {:ok, room_id} = Room.create(user)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/members", %{})
      user_id = user.id
      assert %{"chunk" => [%{"sender" => ^user_id} = membership_event]} = json_response(conn, 200)
      assert "join" = membership_event["content"]["membership"]
    end

    test "returns an M_FORBIDDEN (403) error when requester is not in the room", %{conn: conn} do
      {:ok, creator} =
        "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")

      Repo.insert(creator)

      {:ok, room_id} = Room.create(creator)

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/members", %{})
      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end
end
