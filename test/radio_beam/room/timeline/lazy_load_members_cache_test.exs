defmodule RadioBeam.Room.Timeline.LazyLoadMembersCacheTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache

  setup do
    user = Fixtures.user()
    device = Fixtures.device(user.id)
    {:ok, room_id} = Room.create(user)
    %{user: user, device: device, room_id: room_id}
  end

  describe "get/2" do
    test "works", %{user: user, device: device, room_id: room_id} do
      another_device_id = "helloimadevice"

      {user_ids1, user_ids2} =
        [user.id, "@iamauser:id", "@hello:world", "@testing:onetwothree"]
        |> Enum.shuffle()
        |> Enum.split(2)

      room_ids = [room_id, "!roomid"]

      for room_id <- room_ids do
        true = LazyLoadMembersCache.put(device.id, room_id, user_ids1)
        true = LazyLoadMembersCache.put(another_device_id, room_id, user_ids2)
      end

      assert %{^room_id => usermapset, "!roomid" => usermapset} = LazyLoadMembersCache.get(room_ids, device.id)
      assert Enum.sort(user_ids1) == usermapset |> MapSet.to_list() |> Enum.sort()

      assert %{^room_id => usermapset, "!roomid" => usermapset} = LazyLoadMembersCache.get(room_ids, another_device_id)
      assert Enum.sort(user_ids2) == usermapset |> MapSet.to_list() |> Enum.sort()
    end
  end

  describe "mark_dirty/2" do
    test "marks the given user IDs room memberships as dirty by removing their entries", %{
      user: user,
      device: device,
      room_id: room_id
    } do
      another_device_id = "weirddevice"

      user_ids1 = [user.id, "@reallyweirdguy:id"]
      user_ids2 = user.id

      room_ids = [room_id, "!oddroom"]

      for room_id <- room_ids do
        true = LazyLoadMembersCache.put(device.id, room_id, user_ids1)
        true = LazyLoadMembersCache.put(another_device_id, room_id, user_ids2)
      end

      assert %{^room_id => usermapset} = LazyLoadMembersCache.get(room_ids, device.id)
      assert Enum.sort(user_ids1) == usermapset |> MapSet.to_list() |> Enum.sort()

      true = LazyLoadMembersCache.mark_dirty(room_id, user.id)

      assert %{^room_id => usermapset, "!oddroom" => usermapset2} = LazyLoadMembersCache.get(room_ids, device.id)
      assert ["@reallyweirdguy:id"] == MapSet.to_list(usermapset)
      assert Enum.sort(user_ids1) == usermapset2 |> MapSet.to_list() |> Enum.sort()

      assert %{"!oddroom" => usermapset} = room_map = LazyLoadMembersCache.get(room_ids, another_device_id)
      refute is_map_key(room_map, room_id)
      assert [user.id] == MapSet.to_list(usermapset)

      true = LazyLoadMembersCache.mark_dirty("!oddroom", "@reallyweirdguy:id")

      assert %{"!oddroom" => ^usermapset} = ^room_map = LazyLoadMembersCache.get(room_ids, another_device_id)

      %{"!oddroom" => usermapset} = LazyLoadMembersCache.get(room_ids, device.id)
      assert [user.id] == MapSet.to_list(usermapset)
    end
  end
end
