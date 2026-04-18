defmodule RadioBeamWeb.AccountControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Room
  alias RadioBeam.User

  describe "put_config/2" do
    test "successfully puts global account data", %{conn: conn, account: %{user_id: user_id}} do
      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/account_data/m.some_config", %{"key" => "value"})

      assert res = json_response(conn, 200)
      assert 0 = map_size(res)
    end

    test "cannot put account data under another user", %{conn: conn} do
      conn =
        put(conn, ~p"/_matrix/client/v3/user/@someoneelse:localhost/account_data/m.some_config", %{"key" => "value"})

      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "You cannot put account data for other users"
    end

    test "cannot put m.fully_read or m.push_rules account data", %{conn: conn, account: %{user_id: user_id}} do
      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/account_data/m.fully_read", %{"key" => "value"})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 405)
      assert error =~ "Cannot set m.fully_read"

      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/account_data/m.push_rules", %{"key" => "value"})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 405)
      assert error =~ "Cannot set m.push_rules"
    end

    test "successfully puts room account data", %{conn: conn, account: account} do
      {:ok, room_id} = Room.create(account.user_id)

      conn =
        put(conn, ~p"/_matrix/client/v3/user/#{account.user_id}/rooms/#{room_id}/account_data/m.some_config", %{
          "key" => "value"
        })

      assert res = json_response(conn, 200)
      assert 0 = map_size(res)
    end

    test "cannot put room account data under another user", %{conn: conn, account: account} do
      {:ok, room_id} = Room.create(account.user_id)

      conn =
        put(conn, ~p"/_matrix/client/v3/user/@someoneelse:localhost/rooms/#{room_id}/account_data/m.some_config", %{
          "key" => "value"
        })

      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "You cannot put account data for other users"
    end

    test "cannot put m.fully_read or m.push_rules room account data", %{conn: conn, account: %{user_id: user_id}} do
      {:ok, room_id} = Room.create(user_id)

      conn =
        put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/account_data/m.fully_read", %{"key" => "value"})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 405)
      assert error =~ "Cannot set m.fully_read"

      conn =
        put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/account_data/m.push_rules", %{"key" => "value"})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 405)
      assert error =~ "Cannot set m.push_rules"
    end

    test "cannot set room account data for a non-existent room", %{conn: conn, account: %{user_id: user_id}} do
      conn =
        put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/!what:localhost/account_data/m.some_config", %{
          "key" => "value"
        })

      assert %{"errcode" => "M_INVALID_PARAM", "error" => error} = json_response(conn, 400)
      assert error =~ ""
    end
  end

  describe "get_config/2" do
    setup %{account: %{user_id: user_id}} do
      User.put_account_data(user_id, :global, "m.some_config", %{"key" => "value"})
      {:ok, room_id} = Room.create(user_id)
      User.put_account_data(user_id, room_id, "m.some_config", %{"other" => "value"})

      %{room_id: room_id}
    end

    test "successfully gets global account config", %{conn: conn, account: %{user_id: user_id}} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/account_data/m.some_config", %{})

      assert %{"key" => "value"} = json_response(conn, 200)
    end

    test "cannot get global account config for another user", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v3/user/@someoneelse:localhost/account_data/m.some_config", %{})

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "cannot get global account config that hasn't been set", %{conn: conn, account: %{user_id: user_id}} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/account_data/m.what", %{})

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "successfully gets room account config", %{conn: conn, account: %{user_id: user_id}, room_id: room_id} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/account_data/m.some_config", %{})

      assert %{"other" => "value"} = json_response(conn, 200)
    end

    test "cannot get room account config for another user", %{conn: conn, room_id: room_id} do
      conn =
        get(conn, ~p"/_matrix/client/v3/user/@someoneelse:localhost/rooms/#{room_id}/account_data/m.some_config", %{})

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "cannot get room account config that hasn't been set", %{
      conn: conn,
      account: %{user_id: user_id},
      room_id: room_id
    } do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/account_data/m.what", %{})

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "cannot get room account config for a room that doesn't exist", %{conn: conn, account: %{user_id: user_id}} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/!what:localhost/account_data/m.some_config", %{})

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end
  end

  describe "put_tag/2" do
    test "returns an empty JSON object (200) when setting a tag", %{conn: conn, account: %{user_id: user_id}} do
      {:ok, room_id} = Room.create(user_id)
      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/tags/m.favourite", %{order: 0.5})

      assert %{} = resp = json_response(conn, 200)
      assert 0 = map_size(resp)
    end

    test "returns M_INVALID_PARAM (400) when given an invalid room ID", %{conn: conn, account: %{user_id: user_id}} do
      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/!asdfasdhf/tags/m.favourite", %{order: 0.5})

      assert %{"errcode" => "M_INVALID_PARAM", "error" => "invalid room ID"} = json_response(conn, 400)
    end

    test "returns M_BAD_JSON (400) when given an invalid order", %{conn: conn, account: %{user_id: user_id}} do
      {:ok, room_id} = Room.create(user_id)
      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/tags/m.favourite", %{order: 1.5})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 400)
      assert error =~ "invalid_order"
    end
  end

  describe "get_tags/2" do
    test "returns an empty JSON object (200) when no tags have been put on the room", %{
      conn: conn,
      account: %{user_id: user_id}
    } do
      {:ok, room_id} = Room.create(user_id)
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/tags", %{})

      assert %{"tags" => tags} = json_response(conn, 200)
      assert 0 = map_size(tags)

      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/!asdgyuf/tags", %{})

      assert %{"tags" => tags} = json_response(conn, 200)
      assert 0 = map_size(tags)
    end

    test "returns tags (200) on the room", %{
      conn: conn,
      account: %{user_id: user_id}
    } do
      {:ok, room_id} = Room.create(user_id)
      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/tags/m.favourite", %{order: 0.5})
      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/tags/u.my_tag", %{order: 0.9})

      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/tags", %{})

      assert %{"tags" => %{"m.favourite" => %{"order" => 0.5}, "u.my_tag" => %{"order" => 0.9}} = tags} =
               json_response(conn, 200)

      assert 2 = map_size(tags)
    end
  end

  describe "delete_tag/2" do
    test "returns an empty JSON object (200) when deleting a tag", %{conn: conn, account: %{user_id: user_id}} do
      {:ok, room_id} = Room.create(user_id)
      :ok = User.put_room_tag(user_id, room_id, "m.favourite", 0.5)

      conn = delete(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/tags/m.favourite", %{})

      assert %{} = resp = json_response(conn, 200)
      assert 0 = map_size(resp)
    end

    test "returns M_INVALID_PARAM (400) when given an invalid room ID", %{conn: conn, account: %{user_id: user_id}} do
      conn = delete(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/!asdfasdhf/tags/m.favourite", %{})

      assert %{"errcode" => "M_INVALID_PARAM", "error" => "invalid room ID"} = json_response(conn, 400)
    end
  end
end
