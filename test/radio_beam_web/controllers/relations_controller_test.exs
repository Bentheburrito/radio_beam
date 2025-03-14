defmodule RadioBeamWeb.RelationsContnrollerTest do
  alias RadioBeam.Room
  use RadioBeamWeb.ConnCase, async: true

  defp relates_to(parent_id) do
    %{
      "m.relates_to" => %{
        "rel_type" => "m.thread",
        "event_id" => parent_id
      }
    }
  end

  describe "get_children/2" do
    setup %{conn: conn} do
      {user, device} = Fixtures.device(Fixtures.user(), "da steam deck")

      {:ok, room_id} = Room.create(user)
      {:ok, event_id} = Fixtures.send_text_msg(room_id, user.id, "this is the parent event")

      %{
        conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"),
        room_id: room_id,
        user: user,
        parent_event_id: event_id
      }
    end

    test "returns an empty chunk when the given event has no children", %{
      conn: conn,
      room_id: room_id,
      parent_event_id: parent_event_id
    } do
      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}", %{})
      assert %{"chunk" => []} = json_response(conn, 200)
    end

    test "returns all child events of the given event if they are authz'd", %{
      conn: conn,
      room_id: room_id,
      user: user,
      parent_event_id: parent_event_id
    } do
      rel = relates_to(parent_event_id)
      {:ok, child_id1} = Fixtures.send_text_msg(room_id, user.id, "hello starting a thread here", rel)
      {:ok, child_id2} = Fixtures.send_text_msg(room_id, user.id, "details coming soon", rel)

      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}", %{})
      assert %{"chunk" => [%{"event_id" => ^child_id2}, %{"event_id" => ^child_id1}]} = json_response(conn, 200)
    end

    test "returns all child events of the given rel_type if they are authz'd", %{
      conn: conn,
      room_id: room_id,
      user: user,
      parent_event_id: parent_event_id
    } do
      rel = relates_to(parent_event_id)
      {:ok, child_id1} = Fixtures.send_text_msg(room_id, user.id, "hello starting a thread here", rel)
      {:ok, child_id2} = Fixtures.send_text_msg(room_id, user.id, "details coming soon", rel)

      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}/m.thread", %{})
      assert %{"chunk" => [%{"event_id" => ^child_id2}, %{"event_id" => ^child_id1}]} = json_response(conn, 200)
      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}/m.whatever", %{})
      assert %{"chunk" => []} = json_response(conn, 200)
    end

    test "returns all child events of the given rel_type + event_type if they are authz'd", %{
      conn: conn,
      room_id: room_id,
      user: user,
      parent_event_id: parent_event_id
    } do
      rel = relates_to(parent_event_id)
      {:ok, child_id1} = Fixtures.send_text_msg(room_id, user.id, "hello starting a thread here", rel)
      {:ok, child_id2} = Fixtures.send_text_msg(room_id, user.id, "details coming soon", rel)

      conn =
        get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}/m.thread/m.room.message", %{})

      assert %{"chunk" => [%{"event_id" => ^child_id2}, %{"event_id" => ^child_id1}]} = json_response(conn, 200)

      conn =
        get(
          conn,
          ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}/m.thread/m.room.somethingelse",
          %{}
        )

      assert %{"chunk" => []} = json_response(conn, 200)
    end

    test "returns M_NOT_FOUND when the user is not authz'd to see the parent", %{
      conn: conn,
      room_id: room_id,
      parent_event_id: parent_event_id
    } do
      {user, device} = Fixtures.device(Fixtures.user())
      conn = put_req_header(conn, "authorization", "Bearer #{device.access_token}")
      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}", %{})

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "returns M_NOT_FOUND the parent is not found", %{
      conn: conn,
      room_id: room_id
    } do
      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/$randomevid123", %{})
      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "does not return children which the user is not authz'd to see (after they left the room)", %{
      conn: conn,
      room_id: room_id,
      user: user,
      parent_event_id: parent_event_id
    } do
      {user2, device} = Fixtures.device(Fixtures.user())

      {:ok, _} = Room.invite(room_id, user.id, user2.id)
      {:ok, _} = Room.join(room_id, user2.id)

      rel = relates_to(parent_event_id)
      {:ok, _child_id1} = Fixtures.send_text_msg(room_id, user2.id, "hello starting a thread here", rel)
      {:ok, _child_id2} = Fixtures.send_text_msg(room_id, user.id, "details coming soon", rel)

      {:ok, _} = Room.leave(room_id, user2.id, "details never came :/")

      {:ok, child_id3} = Fixtures.send_text_msg(room_id, user.id, "so impatient :/", rel)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{device.access_token}")
        |> get(~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}", %{})

      assert %{"chunk" => chunk} = json_response(conn, 200)
      assert 2 = length(chunk)
      refute Enum.any?(chunk, &(&1["event_id"] == child_id3))
    end
  end
end
