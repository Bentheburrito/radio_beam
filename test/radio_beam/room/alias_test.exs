defmodule RadioBeam.Room.AliasTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Alias

  describe "put/2" do
    setup do
      %{user: Fixtures.user()}
    end

    test "successfully maps a new alias if the room exists and the alias is not already used", %{user: user} do
      {:ok, room_id} = Room.create(user)
      alias = "#nottaken:localhost"
      assert {:ok, %Alias{alias: ^alias, room_id: ^room_id}} = Alias.put(alias, room_id)
    end

    test "errors with :room_does_not_exist when the room ID doesn't exist" do
      alias = "#validnottaken:localhost"
      assert {:error, :room_does_not_exist} = Alias.put(alias, "!some:room")
    end

    test "errors with :alias_in_use when the given alias is already mapped to a room ID", %{user: user} do
      {:ok, room_id} = Room.create(user)
      alias = "#uhoh:localhost"
      Alias.put(alias, room_id)

      {:ok, another_room_id} = Room.create(user)
      assert {:error, :alias_in_use} = Alias.put(alias, another_room_id)
    end
  end
end
