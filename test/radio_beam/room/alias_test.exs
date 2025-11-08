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

      alias_localpart = "nottaken"
      alias_servername = "localhost"
      alias = "##{alias_localpart}:#{alias_servername}"

      assert {:ok, %Alias{alias_tuple: {^alias_localpart, ^alias_servername}, room_id: ^room_id}} =
               Alias.put(alias, room_id)
    end

    test "errors with :invalid_aliaswhen localpart contains ':'" do
      invalid_alias_localpart = "hello:world"
      alias = "##{invalid_alias_localpart}:localhost"
      assert {:error, :invalid_alias} = Alias.put(alias, "!asdf:localhost")
    end

    test "errors with :invalid_alias_localpart when localpart contains null byte or ':'" do
      invalid_alias_localpart = <<"helloworld", 0>>
      alias = "##{invalid_alias_localpart}:localhost"
      assert {:error, :invalid_alias_localpart} = Alias.put(alias, "!asdf:localhost")
    end

    test "errors with :invalid_or_unknown_server_name when servername does not match this homeserver" do
      alias = "#helloworld:blahblah"
      assert {:error, :invalid_or_unknown_server_name} = Alias.put(alias, "!asdf:localhost")
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
