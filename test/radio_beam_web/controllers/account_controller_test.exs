defmodule RadioBeamWeb.AccountControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Room
  alias RadioBeam.User.Account

  describe "put_config/2" do
    test "successfully puts global account data", %{conn: conn, user: %{id: user_id}} do
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

    test "cannot put m.fully_read or m.push_rules account data", %{conn: conn, user: %{id: user_id}} do
      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/account_data/m.fully_read", %{"key" => "value"})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 405)
      assert error =~ "Cannot set m.fully_read"

      conn = put(conn, ~p"/_matrix/client/v3/user/#{user_id}/account_data/m.push_rules", %{"key" => "value"})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 405)
      assert error =~ "Cannot set m.push_rules"
    end

    test "successfully puts room account data", %{conn: conn, user: user} do
      {:ok, room_id} = Room.create(user)

      conn =
        put(conn, ~p"/_matrix/client/v3/user/#{user.id}/rooms/#{room_id}/account_data/m.some_config", %{
          "key" => "value"
        })

      assert res = json_response(conn, 200)
      assert 0 = map_size(res)
    end

    test "cannot put room account data under another user", %{conn: conn, user: user} do
      {:ok, room_id} = Room.create(user)

      conn =
        put(conn, ~p"/_matrix/client/v3/user/@someoneelse:localhost/rooms/#{room_id}/account_data/m.some_config", %{
          "key" => "value"
        })

      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "You cannot put account data for other users"
    end

    test "cannot put m.fully_read or m.push_rules room account data", %{conn: conn, user: %{id: user_id} = user} do
      {:ok, room_id} = Room.create(user)

      conn =
        put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/account_data/m.fully_read", %{"key" => "value"})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 405)
      assert error =~ "Cannot set m.fully_read"

      conn =
        put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/account_data/m.push_rules", %{"key" => "value"})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 405)
      assert error =~ "Cannot set m.push_rules"
    end

    test "cannot set room account data for a non-existent room", %{conn: conn, user: %{id: user_id}} do
      conn =
        put(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/!what:localhost/account_data/m.some_config", %{
          "key" => "value"
        })

      assert %{"errcode" => "M_INVALID_PARAM", "error" => error} = json_response(conn, 400)
      assert error =~ ""
    end
  end

  describe "get_config/2" do
    setup %{user: %{id: user_id} = user} do
      Account.put(user_id, :global, "m.some_config", %{"key" => "value"})
      {:ok, room_id} = Room.create(user)
      Account.put(user_id, room_id, "m.some_config", %{"other" => "value"})

      %{room_id: room_id}
    end

    test "successfully gets global account config", %{conn: conn, user: %{id: user_id}} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/account_data/m.some_config", %{})

      assert %{"key" => "value"} = json_response(conn, 200)
    end

    test "cannot get global account config for another user", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v3/user/@someoneelse:localhost/account_data/m.some_config", %{})

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "cannot get global account config that hasn't been set", %{conn: conn, user: %{id: user_id}} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/account_data/m.what", %{})

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "successfully gets room account config", %{conn: conn, user: %{id: user_id}, room_id: room_id} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/account_data/m.some_config", %{})

      assert %{"other" => "value"} = json_response(conn, 200)
    end

    test "cannot get room account config for another user", %{conn: conn, room_id: room_id} do
      conn =
        get(conn, ~p"/_matrix/client/v3/user/@someoneelse:localhost/rooms/#{room_id}/account_data/m.some_config", %{})

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "cannot get room account config that hasn't been set", %{conn: conn, user: %{id: user_id}, room_id: room_id} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/#{room_id}/account_data/m.what", %{})

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "cannot get room account config for a room that doesn't exist", %{conn: conn, user: %{id: user_id}} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/rooms/!what:localhost/account_data/m.some_config", %{})

      assert %{"errcode" => "M_INVALID_PARAM"} = json_response(conn, 400)
    end
  end
end
