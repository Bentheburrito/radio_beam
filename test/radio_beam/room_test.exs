defmodule RadioBeam.RoomTest do
  use ExUnit.Case

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
        assert {:ok, room_id} = Room.create(room_version, creator)
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
        name: "The Computer Room",
        topic: "this one's for the nerds",
        direct?: false,
        visibility: :public,
        invite: [invitee.id],
        # TODO
        invite_3pid: []
      ]

      create_content = %{"m.federate" => false}

      for room_version <- @room_versions_to_test do
        assert {:ok, room_id} = Room.create(room_version, creator, create_content, opts)
        assert [{pid, _}] = Registry.lookup(RoomRegistry, room_id)
        assert is_pid(pid)

        assert {:ok, %Room{id: ^room_id, version: ^room_version, state: state}} = Repo.get(Room, room_id)
        assert %{"membership" => "join"} = get_in(state, [{"m.room.member", creator.id}, "content"])

        pl_content = Map.merge(Room.default_power_level_content(creator.id), power_levels_content)

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
