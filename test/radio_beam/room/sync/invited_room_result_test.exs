defmodule RadioBeam.Room.Sync.InvitedRoomResultTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Room
  alias RadioBeam.Room.Events

  setup do
    account = Fixtures.create_account()

    events =
      Enum.map(
        [
          Events.create(&Room.generate_legacy_id/0, account.user_id, "11", %{}),
          Events.state("!abcde", "m.room.join_rules", account.user_id, %{"join_rule" => "invite"}),
          Events.name("!abcde", account.user_id, "A Room"),
          Events.membership("!abcde", account.user_id, account.user_id, :invite)
        ],
        &Map.take(&1, ~w|content sender state_key type|)
      )

    %{user_id: account.user_id, events: events}
  end

  describe "new!/2" do
    test "creates a new InvitedRoomResult for a user from the given %Room{} and user_id", %{events: events} do
      assert %InvitedRoomResult{stripped_state_events: ^events} = InvitedRoomResult.new!("!abcde", events)
    end
  end

  describe "JSON.Encoder implementation" do
    test "encodes an InvitedRoomResult as expected by the C-S spec", %{events: events} do
      %InvitedRoomResult{} = invited_room_result = InvitedRoomResult.new!("!abcde", events)

      assert json = JSON.encode!(invited_room_result)
      assert json =~ ~s|{"invite_state":{"events":[|
      assert json =~ ~s|"type":"m.room.create"|
      assert json =~ ~s|"type":"m.room.join_rules"|
      assert json =~ ~s|"type":"m.room.member"|
      assert json =~ ~s|"type":"m.room.name"|
      refute json =~ ~s|"type":"m.room.message"|
      refute json =~ ~s|unsigned|
    end
  end
end
