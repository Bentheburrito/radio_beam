defmodule RadioBeam.RoomTest do
  use ExUnit.Case

  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.PDU
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.RoomAlias
  alias RadioBeam.RoomRegistry
  alias RadioBeam.User

  # TODO: add more room versions here as support is implemented
  @room_versions_to_test ["5"]

  describe "create/4" do
    setup do
      {:ok, user} = User.new("@thecreator:localhost", "Asdf123$")
      {:ok, user} = Repo.insert(user)
      {:ok, invitee} = User.new("@agoodfriend:localhost", "AAsdf123$")
      {:ok, invitee} = Repo.insert(invitee)

      %{creator: user, to_invite: invitee}
    end

    test "successfully creates a minimal room", %{creator: creator} do
      for room_version <- @room_versions_to_test do
        assert {:ok, room_id} = Room.create(creator)
        assert [{pid, _}] = Registry.lookup(RoomRegistry, room_id)
        assert is_pid(pid)

        assert {:ok, %Room{id: ^room_id, version: ^room_version, state: state}} = Repo.get(Room, room_id)
        assert %{"membership" => "join"} = get_in(state, [{"m.room.member", creator.id}, "content"])
      end
    end

    test "successfully creates a room with all the different optional args", %{creator: creator, to_invite: invitee} do
      server_name = RadioBeam.server_name()
      power_levels_content = %{"users" => %{creator.id => 99}, "ban" => "60", "state_default" => 51}

      opts = [
        power_levels: power_levels_content,
        preset: :trusted_private_chat,
        # override the join_rules of the preset, but name should not affect anything
        addl_state_events: [join_rule_event(), name_event()],
        alias: "computer",
        content: %{"m.federate" => false},
        name: "The Computer Room",
        topic: "this one's for the nerds",
        direct?: false,
        visibility: :public,
        invite: [invitee.id],
        # TODO
        invite_3pid: []
      ]

      for room_version <- @room_versions_to_test do
        assert {:ok, room_id} = Room.create(creator, opts)
        assert [{pid, _}] = Registry.lookup(RoomRegistry, room_id)
        assert is_pid(pid)

        assert {:ok, %Room{id: ^room_id, version: ^room_version, state: state}} = Repo.get(Room, room_id)
        assert %{"membership" => "join"} = get_in(state, [{"m.room.member", creator.id}, "content"])

        pl_content = Map.merge(Room.Utils.default_power_level_content(creator.id), power_levels_content)

        assert ^pl_content = get_in(state, [{"m.room.power_levels", ""}, "content"])

        # preset trusted_private_chat sets join_rule to "invite", but we override with "knock"
        assert %{"join_rule" => "knock"} = get_in(state, [{"m.room.join_rules", ""}, "content"])
        assert %{"history_visibility" => "shared"} = get_in(state, [{"m.room.history_visibility", ""}, "content"])
        assert %{"guest_access" => "can_join"} = get_in(state, [{"m.room.guest_access", ""}, "content"])

        alias = "#computer:#{server_name}"
        assert %{"alias" => ^alias} = get_in(state, [{"m.room.canonical_alias", ""}, "content"])
        assert {:ok, %RoomAlias{alias: ^alias, room_id: ^room_id}} = Repo.get(RoomAlias, alias)

        assert %{"name" => "The Computer Room"} = get_in(state, [{"m.room.name", ""}, "content"])
        assert %{"topic" => "this one's for the nerds"} = get_in(state, [{"m.room.topic", ""}, "content"])

        assert %{"membership" => "invite"} = get_in(state, [{"m.room.member", invitee.id}, "content"])
        # TODO: assert invite_3pid, direct?, and visibility
      end
    end
  end

  describe "joined/1" do
    setup do
      {:ok, user1} = User.new("@thehost:localhost", "Asdf123$")
      {:ok, user1} = Repo.insert(user1)
      {:ok, user2} = User.new("@friendoftheshow:localhost", "AAsdf123$")
      {:ok, user2} = Repo.insert(user2)

      %{user1: user1, user2: user2}
    end

    test "lists a user's room appropriately", %{user1: user1, user2: user2} do
      assert [] = Room.joined(user1.id)

      assert {:ok, room_id} = Room.create(user1)
      assert [^room_id] = Room.joined(user1.id)

      assert {:ok, _other_users_room_id} = Room.create(user2)
      assert [^room_id] = Room.joined(user1.id)

      assert {:ok, _other_users_room_id} = Room.create(user2, invite: [user1.id])
      assert [^room_id] = Room.joined(user1.id)

      assert {:ok, room_id2} = Room.create(user1)
      assert Enum.sort([room_id, room_id2]) == Enum.sort(Room.joined(user1.id))
    end
  end

  describe "invite/3" do
    setup do
      {:ok, user1} = User.new("@theboss:localhost", "Asdf123$")
      {:ok, user1} = Repo.insert(user1)
      {:ok, user2} = User.new("@newhire:localhost", "AAsdf123$")
      {:ok, user2} = Repo.insert(user2)

      %{user1: user1, user2: user2}
    end

    test "successfully invites a user", %{user1: user1, user2: user2} do
      {:ok, room_id} = Room.create(user1)

      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      refute is_map_key(state, {"m.room.member", user2.id})

      assert {:ok, _event_id} = Room.invite(room_id, user1.id, user2.id)

      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      assert "invite" = get_in(state, [{"m.room.member", user2.id}, "content", "membership"])
    end

    test "fails with :unauthorized when the inviter does not have a high enough PL", %{user1: user1, user2: user2} do
      {:ok, room_id} = Room.create(user1, power_levels: %{"invite" => 101})

      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      refute is_map_key(state, {"m.room.member", user2.id})

      assert {:error, :unauthorized} = Room.invite(room_id, user1.id, user2.id)
    end
  end

  describe "join/2" do
    setup do
      {:ok, user1} = User.new("@bodyguard:localhost", "Asdf123$")
      {:ok, user1} = Repo.insert(user1)
      {:ok, user2} = User.new("@iloveclubaqua:localhost", "AAsdf123$")
      {:ok, user2} = Repo.insert(user2)

      %{user1: user1, user2: user2}
    end

    test "successfully joins the room", %{user1: user1, user2: user2} do
      {:ok, room_id} = Room.create(user1)

      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      refute is_map_key(state, {"m.room.member", user2.id})
      assert {:ok, _event_id} = Room.invite(room_id, user1.id, user2.id)
      reason = "requested assistance"
      assert {:ok, _event_id} = Room.join(room_id, user2.id, reason)

      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      assert "join" = get_in(state, [{"m.room.member", user2.id}, "content", "membership"])
      assert ^reason = get_in(state, [{"m.room.member", user2.id}, "content", "reason"])
    end

    test "fails with :unauthorized when the joiner has not been invited", %{user1: user1, user2: user2} do
      {:ok, room_id} = Room.create(user1)

      {:ok, %Room{state: state}} = Repo.get(Room, room_id)
      refute is_map_key(state, {"m.room.member", user2.id})

      assert {:error, :unauthorized} = Room.join(room_id, user2.id)
    end
  end

  describe "send/4" do
    setup do
      {:ok, user1} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
      {:ok, user1} = Repo.insert(user1)
      {:ok, user2} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
      {:ok, user2} = Repo.insert(user2)

      %{user1: user1, user2: user2}
    end

    test "creator can put a message in the room", %{user1: %{id: creator_id} = creator} do
      {:ok, room_id} = Room.create(creator)

      content = %{"msgtype" => "m.text", "body" => "This is a test message"}
      assert {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)
      assert {:ok, %{latest_event_ids: [^event_id]}} = Repo.get(Room, room_id)
      assert %{^event_id => %{sender: ^creator_id}} = PDU.get([event_id])
    end

    test "member can put a message in the room if has perms", %{user1: creator, user2: %{id: user_id} = user} do
      {:ok, room_id} = Room.create(creator)
      assert {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      assert {:ok, _event_id} = Room.join(room_id, user.id)

      content = %{"msgtype" => "m.text", "body" => "This is another test message"}
      assert {:ok, event_id} = Room.send(room_id, user.id, "m.room.message", content)
      assert {:ok, %{latest_event_ids: [^event_id]}} = Repo.get(Room, room_id)
      assert %{^event_id => %{sender: ^user_id}} = PDU.get([event_id])
    end

    test "member can't put a message in the room without perms", %{user1: creator, user2: user} do
      {:ok, room_id} = Room.create(creator, power_levels: %{"events" => %{"m.room.message" => 80}})
      assert {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      assert {:ok, _event_id} = Room.join(room_id, user.id)

      {:ok, %{latest_event_ids: [event_id]}} = Repo.get(Room, room_id)

      content = %{"msgtype" => "m.text", "body" => "I shouldn't be able to send this rn"}
      assert {:error, :unauthorized} = Room.send(room_id, user.id, "m.room.message", content)
      assert {:ok, %{latest_event_ids: [^event_id]}} = Repo.get(Room, room_id)
    end

    test "member can't put a message in the room without first joining", %{user1: creator, user2: user} do
      {:ok, room_id} = Room.create(creator)
      assert {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)

      {:ok, %{latest_event_ids: [event_id]}} = Repo.get(Room, room_id)

      content = %{"msgtype" => "m.text", "body" => "I shouldn't be able to send this rn"}
      assert {:error, :unauthorized} = Room.send(room_id, user.id, "m.room.message", content)
      assert {:ok, %{latest_event_ids: [^event_id]}} = Repo.get(Room, room_id)
    end
  end

  defp join_rule_event() do
    %{
      "content" => %{"join_rule" => "knock"},
      "state_key" => "",
      "type" => "m.room.join_rules"
    }
  end

  defp name_event() do
    %{
      "content" => %{"name" => "sloppy steak house"},
      "state_key" => "",
      "type" => "m.room.name"
    }
  end
end
