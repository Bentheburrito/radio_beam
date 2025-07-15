defmodule RadioBeam.Room.Sync.InvitedRoomResultTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Room

  describe "new/2" do
    test "creates a new InvitedRoomResult for a user from the given %Room{} and user_id" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, room} = RadioBeam.Repo.fetch(Room, room_id)

      invited_room_result = InvitedRoomResult.new(room, user.id)

      assert invited_room_result.stripped_state_events == Room.stripped_state(room, user.id)
      assert room_id == invited_room_result.room_id
    end
  end

  describe "Jason.Encoder implementation" do
    test "encodes an InvitedRoomResult as expected by the C-S spec" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, room} = RadioBeam.Repo.fetch(Room, room_id)

      Fixtures.send_text_msg(room_id, user.id, "helloooooooo")

      %InvitedRoomResult{} = invited_room_result = InvitedRoomResult.new(room, user.id)

      assert {:ok, json} = Jason.encode(invited_room_result)
      assert json =~ ~s|{"invite_state":{"events":[|
      assert json =~ ~s|{"type":"m.room.create"|
      assert json =~ ~s|{"type":"m.room.join_rules"|
      assert json =~ ~s|{"type":"m.room.member"|
      refute json =~ ~s|{"type":"m.room.message"|
    end
  end
end
