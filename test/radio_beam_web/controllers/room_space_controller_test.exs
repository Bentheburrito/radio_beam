defmodule RadioBeamWeb.RoomSpaceControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Room

  setup %{account: account} do
    queue = {RadioBeam.User.RoomMemberships, account.user_id}
    Fixtures.listen_to_queue_messages(queue)

    {:ok, room_id} = Room.create(account.user_id)

    Fixtures.assert_processed_count(queue, 1, 500)

    :pong = Room.Server.ping(room_id)

    %{room_id: room_id, queue: queue}
  end

  describe "hierarchy/2" do
    test "returns an empty list when there are no child rooms", %{conn: conn, room_id: room_id} do
      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/hierarchy")

      assert %{"rooms" => []} = json_response(conn, 200)
    end

    test "returns child rooms", %{conn: conn, room_id: room_id, account: %{user_id: user_id}, queue: queue} do
      {:ok, another_room_id} = Room.create(user_id)
      {:ok, _} = Room.put_state(room_id, user_id, "m.space.child", another_room_id, %{"via" => ["some.cool.server"]})

      Fixtures.assert_processed_count(queue, 1)

      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/hierarchy")

      assert %{"rooms" => [%{"room_id" => ^another_room_id}]} = json_response(conn, 200)
    end

    test "returns child rooms in a depth-first manner", %{
      conn: conn,
      room_id: room_id,
      account: %{user_id: user_id},
      queue: queue
    } do
      {:ok, subspace_id} = Room.create(user_id, content: %{"type" => "m.space"})
      {:ok, super_subspace_id} = Room.create(user_id, content: %{"type" => "m.space"})
      {:ok, super_subspace_child_id} = Room.create(user_id)
      {:ok, subspace_child_id} = Room.create(user_id)
      {:ok, child_id} = Room.create(user_id)

      Fixtures.assert_processed_count(queue, 5)

      content = %{"via" => ["some.cool.server"]}

      #                  room_id
      #                /         \
      #           subspace_id    child_id
      #          /          \
      # subspace_child_id   super_subspace_id
      #                                  \
      #                         super_subspace_child_id
      # expected order in DFS:
      # subspace_id, subspace_child_id, super_subspace_id, super_subspace_child_id, child_id
      #
      {:ok, _} = Room.put_state(room_id, user_id, "m.space.child", subspace_id, content)
      {:ok, _} = Room.put_state(room_id, user_id, "m.space.child", child_id, content)
      {:ok, _} = Room.put_state(subspace_id, user_id, "m.space.child", subspace_child_id, content)
      {:ok, _} = Room.put_state(super_subspace_id, user_id, "m.space.child", super_subspace_child_id, content)
      {:ok, _} = Room.put_state(subspace_id, user_id, "m.space.child", super_subspace_id, content)

      for id <- [room_id, subspace_id, super_subspace_id] do
        :pong = Room.Server.ping(id)
      end

      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/hierarchy")

      assert %{
               "rooms" => [
                 %{"room_id" => ^subspace_id},
                 %{"room_id" => ^subspace_child_id},
                 %{"room_id" => ^super_subspace_id},
                 %{"room_id" => ^super_subspace_child_id},
                 %{"room_id" => ^child_id}
               ]
             } = json_response(conn, 200)
    end

    test "does not return child rooms that the requester isn't joined or invited to, preventing them from peaking info on it",
         %{
           conn: conn,
           room_id: room_id,
           account: %{user_id: user_id}
         } do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, another_room_id} = Room.create(creator_id)
      {:ok, _} = Room.put_state(room_id, user_id, "m.space.child", another_room_id, %{"via" => ["some.cool.server"]})

      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/hierarchy")

      assert %{"rooms" => []} = json_response(conn, 200)
    end

    test "returns M_FORBIDDEN (403) when the given room ID doesn't exist, or the user is not joined to it",
         %{
           conn: conn,
           room_id: room_id,
           account: %{user_id: user_id}
         } do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, another_room_id} = Room.create(creator_id)
      {:ok, _} = Room.put_state(room_id, user_id, "m.space.child", another_room_id, %{"via" => ["some.cool.server"]})

      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{another_room_id}/hierarchy")

      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "does not exist, or you lack permission"

      conn = get(conn, ~p"/_matrix/client/v1/rooms/!idontexistman/hierarchy")

      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "does not exist, or you lack permission"
    end
  end
end
