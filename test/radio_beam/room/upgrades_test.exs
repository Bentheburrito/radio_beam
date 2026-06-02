defmodule RadioBeam.Room.UpgradesTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room

  describe "perform/5 (via Room.upgrade/4)" do
    test "upgrades a room from arbitrary versions, as long as they're supported" do
      supported_versions = Map.keys(RadioBeam.Config.supported_room_versions())

      for from_version <- supported_versions, to_version <- supported_versions, from_version != to_version do
        %{user_id: user_id} = Fixtures.create_account()

        alias_localpart = "room-upgrade-#{from_version}-to-#{to_version}"
        {:ok, room_id} = Room.create(user_id, version: from_version, alias: alias_localpart)
        :pong = Room.Server.ping(room_id)

        assert {:ok, upgraded_room_id} = Room.upgrade(room_id, user_id, to_version, [])
        :pong = Room.Server.ping(upgraded_room_id)

        assert {:ok, %{content: %{"predecessor" => %{"room_id" => ^room_id}}}} =
                 Room.get_state(upgraded_room_id, user_id, "m.room.create", "")

        assert {:ok, tombstone_event} = Room.get_state(room_id, user_id, "m.room.tombstone", "")
        assert %{content: %{"replacement_room" => ^upgraded_room_id}} = tombstone_event

        {:ok, alias} = Room.Alias.new("##{alias_localpart}:#{RadioBeam.server_name()}")
        assert {:ok, ^upgraded_room_id} = Room.lookup_id_by_alias(alias)
      end
    end

    test "returns :unsupported when the room version is not supported" do
      %{user_id: user_id} = Fixtures.create_account()

      assert {:ok, room_id} = Room.create(user_id)

      :pong = Room.Server.ping(room_id)

      assert {:error, :unsupported} = Room.upgrade(room_id, user_id, "'ello", [])
    end

    test "returns :unauthorized when the room does not exist" do
      %{user_id: user_id} = Fixtures.create_account()
      assert {:error, :unauthorized} = Room.upgrade("!asdf12341234", user_id, "12", [])
    end

    test "returns :unauthorized when the upgrader does not have perms to send a tombstone" do
      %{user_id: user_id} = Fixtures.create_account()

      assert {:ok, room_id} =
               Room.create(user_id, version: "11", power_levels: %{"events" => %{"m.room.tombstone" => 101}})

      :pong = Room.Server.ping(room_id)

      assert {:error, :unauthorized} = Room.upgrade(room_id, user_id, "12", [])
    end

    test "adjusts power_levels in the old room in order to encourage migration to the new room" do
      %{user_id: user_id} = Fixtures.create_account()

      {:ok, room_id} = Room.create(user_id, version: "11")
      :pong = Room.Server.ping(room_id)

      assert {:ok, _upgraded_room_id} = Room.upgrade(room_id, user_id, "12", [])

      assert {:ok, %{content: %{"events_default" => 50, "invite" => 50}}} =
               Room.get_state(room_id, user_id, "m.room.power_levels", "")
    end
  end
end
