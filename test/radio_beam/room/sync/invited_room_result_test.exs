defmodule RadioBeam.Room.Sync.InvitedRoomResultTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Room

  describe "new!/2" do
    test "creates a new InvitedRoomResult for a user from the given %Room{} and user_id" do
      user = Fixtures.user()
      room = Fixtures.room("11", user.id)

      invited_room_result = InvitedRoomResult.new!(room, user.id)

      assert Enum.map(invited_room_result.stripped_state_events, & &1.id) ==
               room.state |> Room.State.get_invite_state_pdus(user.id) |> Enum.map(& &1.event.id)

      assert room.id == invited_room_result.room_id
    end
  end

  describe "Jason.Encoder implementation" do
    test "encodes an InvitedRoomResult as expected by the C-S spec" do
      user = Fixtures.user()

      {:sent, room, _pdu} =
        "11"
        |> Fixtures.room(user.id)
        |> Fixtures.send_room_msg(user.id, "helloooooooo")

      %InvitedRoomResult{} = invited_room_result = InvitedRoomResult.new!(room, user.id)

      assert {:ok, json} = Jason.encode(invited_room_result)
      assert json =~ ~s|{"invite_state":{"events":[|
      assert json =~ ~s|{"type":"m.room.create"|
      assert json =~ ~s|{"type":"m.room.join_rules"|
      assert json =~ ~s|{"type":"m.room.member"|
      refute json =~ ~s|{"type":"m.room.message"|
      refute json =~ ~s|unsigned|
    end
  end
end
