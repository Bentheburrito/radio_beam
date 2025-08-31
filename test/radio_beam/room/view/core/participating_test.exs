defmodule RadioBeam.Room.View.Core.ParticipatingTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.View.Core.Participating

  describe "handle_pdu/3" do
    setup do
      creator_id = Fixtures.user_id()
      %{room: Fixtures.room("11", creator_id), creator_id: creator_id, user_id: Fixtures.user_id()}
    end

    test "adds the room ID to `:all` when the PDU is a membership event", %{
      room: room,
      creator_id: creator_id,
      user_id: user_id
    } do
      {:sent, room, pdu} = Fixtures.send_room_membership(room, creator_id, user_id, :invite)
      view = Participating.new!()
      updated_view = Participating.handle_pdu(view, room, pdu)

      assert view.joined == updated_view.joined
      assert MapSet.new([room.id]) == updated_view.all

      {:sent, other_room, pdu} =
        "11" |> Fixtures.room(creator_id) |> Fixtures.send_room_membership(creator_id, user_id, :invite)

      updated_view = Participating.handle_pdu(updated_view, other_room, pdu)

      assert view.joined == updated_view.joined
      assert MapSet.new([room.id, other_room.id]) == updated_view.all
    end

    test "adds the room ID to `:all` and `:joined` when the PDU is a join membership event", %{
      room: room,
      creator_id: creator_id,
      user_id: user_id
    } do
      {:sent, room, _pdu} = Fixtures.send_room_membership(room, creator_id, user_id, :invite)
      {:sent, room, pdu} = Fixtures.send_room_membership(room, user_id, user_id, :join)
      view = Participating.new!()
      updated_view = Participating.handle_pdu(view, room, pdu)

      assert MapSet.new([room.id]) == updated_view.joined
      assert MapSet.new([room.id]) == updated_view.all

      {:sent, other_room, pdu} =
        "11" |> Fixtures.room(creator_id) |> Fixtures.send_room_membership(creator_id, user_id, :ban)

      updated_view = Participating.handle_pdu(updated_view, other_room, pdu)

      assert MapSet.new([room.id]) == updated_view.joined
      assert MapSet.new([room.id, other_room.id]) == updated_view.all
    end
  end
end
