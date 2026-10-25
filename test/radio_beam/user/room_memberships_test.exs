defmodule RadioBeam.User.RoomMembershipsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.User.RoomMemberships

  describe "handle_pdu/2" do
    setup do
      %{user_id: creator_id} = Fixtures.create_account()
      %{user_id: user_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      %{room_id: room_id, creator_id: creator_id, user_id: user_id}
    end

    test "adds the user's membership under the room ID when the PDU is a membership event", %{
      room_id: room_id,
      creator_id: creator_id,
      user_id: user_id
    } do
      assert [] = RoomMemberships.invited(user_id)
      assert [] = RoomMemberships.joined(user_id)
      assert {:error, :not_found} = RoomMemberships.fetch(user_id, room_id)
      refute RoomMemberships.has?(user_id, room_id)

      queue = {RoomMemberships, user_id}
      Fixtures.listen_to_queue_messages(queue)
      {:ok, event_id} = Room.invite(room_id, creator_id, user_id)
      Fixtures.assert_caught_up_to_event(queue, event_id)

      assert [^room_id] = RoomMemberships.invited(user_id)
      assert [] = RoomMemberships.joined(user_id)
      assert {:ok, "invite"} = RoomMemberships.fetch(user_id, room_id)
      assert RoomMemberships.has?(user_id, room_id)

      {:ok, other_room_id} = Room.create(creator_id)
      {:ok, event_id} = Room.invite(other_room_id, creator_id, user_id)
      Fixtures.assert_caught_up_to_event(queue, event_id)

      assert Enum.sort([room_id, other_room_id]) == Enum.sort(RoomMemberships.invited(user_id))
      assert [] = RoomMemberships.joined(user_id)
      assert {:ok, "invite"} = RoomMemberships.fetch(user_id, room_id)
      assert {:ok, "invite"} = RoomMemberships.fetch(user_id, other_room_id)
      assert RoomMemberships.has?(user_id, room_id)
      assert RoomMemberships.has?(user_id, other_room_id)

      {:ok, event_id} = Room.join(other_room_id, user_id)
      Fixtures.assert_caught_up_to_event(queue, event_id)

      assert [^room_id] = RoomMemberships.invited(user_id)
      assert [^other_room_id] = RoomMemberships.joined(user_id)
      assert {:ok, "invite"} = RoomMemberships.fetch(user_id, room_id)
      assert {:ok, "join"} = RoomMemberships.fetch(user_id, other_room_id)
      assert RoomMemberships.has?(user_id, room_id)
      assert RoomMemberships.has?(user_id, other_room_id)
    end
  end
end
