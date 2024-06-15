defmodule RadioBeamWeb.RoomControllerTest do
  use RadioBeamWeb.ConnCase, async: true

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
          %{"type" => "m.room.join_rules", "state_key" => "", "content" => %{"join_rule" => "public"}}
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

      assert %{"membership" => "invite"} = get_in(state, [{"m.room.member", "@bwyatt:#{server_name}"}, "content"])
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

    test "errors with M_UNSUPPORTED_ROOM_VERSION when...well do I need to say more?", %{conn: conn} do
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
end
