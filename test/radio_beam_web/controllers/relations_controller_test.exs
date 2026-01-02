defmodule RadioBeamWeb.RelationsContnrollerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Room

  defp relates_to(parent_id, msg) do
    %{
      "msgtype" => "m.text",
      "body" => msg,
      "m.relates_to" => %{
        "rel_type" => "m.thread",
        "event_id" => parent_id
      }
    }
  end

  describe "get_children/2" do
    setup %{account: account} do
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, event_id} = Room.send_text_message(room_id, account.user_id, "this is the parent event")

      %{
        room_id: room_id,
        account: account,
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
      account: account,
      parent_event_id: parent_event_id
    } do
      content = relates_to(parent_event_id, "hello starting a thread here")
      {:ok, child_id1} = Room.send(room_id, account.user_id, "m.room.message", content)
      content = relates_to(parent_event_id, "details coming soon")
      {:ok, child_id2} = Room.send(room_id, account.user_id, "m.room.message", content)

      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}", %{})
      assert %{"chunk" => [%{"event_id" => ^child_id2}, %{"event_id" => ^child_id1}]} = json_response(conn, 200)
    end

    test "returns all child events of the given rel_type if they are authz'd", %{
      conn: conn,
      room_id: room_id,
      account: account,
      parent_event_id: parent_event_id
    } do
      content = relates_to(parent_event_id, "hello starting a thread here")
      {:ok, child_id1} = Room.send(room_id, account.user_id, "m.room.message", content)
      content = relates_to(parent_event_id, "details coming soon")
      {:ok, child_id2} = Room.send(room_id, account.user_id, "m.room.message", content)

      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}/m.thread", %{})
      assert %{"chunk" => [%{"event_id" => ^child_id2}, %{"event_id" => ^child_id1}]} = json_response(conn, 200)
      conn = get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}/m.whatever", %{})
      assert %{"chunk" => []} = json_response(conn, 200)
    end

    test "returns all child events of the given rel_type + event_type if they are authz'd", %{
      conn: conn,
      room_id: room_id,
      account: account,
      parent_event_id: parent_event_id
    } do
      content = relates_to(parent_event_id, "hello starting a thread here")
      {:ok, child_id1} = Room.send(room_id, account.user_id, "m.room.message", content)
      content = relates_to(parent_event_id, "details coming soon")
      {:ok, child_id2} = Room.send(room_id, account.user_id, "m.room.message", content)

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

    test "returns M_NOT_FOUND when the user is not authz'd to see the parent", %{conn: conn} do
      other_account = Fixtures.create_account()
      {:ok, room_id} = Room.create(other_account.user_id)
      {:ok, parent_event_id} = Room.send_text_message(room_id, other_account.user_id, "this is another parent event")

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
      account: account
    } do
      account2 = Fixtures.create_account()
      {:ok, room_id} = Room.create(account2.user_id)
      {:ok, parent_event_id} = Room.send_text_message(room_id, account2.user_id, "this is another parent event")

      {:ok, _} = Room.invite(room_id, account2.user_id, account.user_id)
      {:ok, _} = Room.join(room_id, account.user_id)

      content = relates_to(parent_event_id, "hello starting a thread here")
      {:ok, _child_id1} = Room.send(room_id, account.user_id, "m.room.message", content)
      content = relates_to(parent_event_id, "details coming soon")
      {:ok, _child_id2} = Room.send(room_id, account2.user_id, "m.room.message", content)

      {:ok, _} = Room.leave(room_id, account.user_id, "details never came :/")

      content = relates_to(parent_event_id, "so impatient :/")
      {:ok, child_id3} = Room.send(room_id, account2.user_id, "m.room.message", content)

      conn =
        get(conn, ~p"/_matrix/client/v1/rooms/#{room_id}/relations/#{parent_event_id}", %{})

      assert %{"chunk" => chunk} = json_response(conn, 200)
      assert 2 = length(chunk)
      refute Enum.any?(chunk, &(&1["event_id"] == child_id3))
    end
  end
end
