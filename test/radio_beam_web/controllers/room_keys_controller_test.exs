defmodule RadioBeamWeb.RoomKeysControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.User.Keys

  @algo "m.megolm_backup.v1.curve25519-aes-sha2"
  @auth_data %{
    "public_key" => "abcdefg",
    "signatures" => %{"@alice:example.org" => %{"ed25519:deviceid" => "signature"}}
  }

  describe "create_backup/2" do
    test "returns the version of the newly created backup", %{conn: conn} do
      req_body = %{"algorithm" => @algo, "auth_data" => @auth_data}

      conn = post(conn, ~p"/_matrix/client/v3/room_keys/version", req_body)

      assert %{"version" => "1"} = json_response(conn, 200)
    end

    test "errors with BAD_JSON (400) when an unsupported algorithm is given", %{conn: conn} do
      req_body = %{"algorithm" => "org.some.other.ago", "auth_data" => @auth_data}

      conn = post(conn, ~p"/_matrix/client/v3/room_keys/version", req_body)

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 400)
      error =~ "algorithm needs to be one of m.megolm_backup.v1.curve25519-aes-sha2"
    end
  end

  describe "get_backup_info/2" do
    test "returns the latest backup when no version param is provided", %{conn: conn, user: user} do
      add_room_keys_with_2_backups_to_user(user.id)
      conn = get(conn, ~p"/_matrix/client/v3/room_keys/version", %{})

      assert %{"version" => "2"} = json_response(conn, 200)
    end

    test "returns M_NOT_FOUND (404) when there is no latest backup", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v3/room_keys/version", %{})

      assert %{"errcode" => "M_NOT_FOUND", "error" => "Backup not found"} = json_response(conn, 404)
    end

    test "returns the backup of the given version", %{conn: conn, user: user} do
      add_room_keys_with_2_backups_to_user(user.id)
      conn = get(conn, ~p"/_matrix/client/v3/room_keys/version/1", %{})

      assert %{"version" => "1"} = json_response(conn, 200)
    end

    test "returns M_NOT_FOUND (404) when no backup exists under the given version", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v3/room_keys/version/1", %{})

      assert %{"errcode" => "M_NOT_FOUND", "error" => "Backup not found"} = json_response(conn, 404)
    end
  end

  describe "put_backup_auth_data/2" do
    test "returns an empty JSON body (200) when the auth data was updated successfully", %{conn: conn, user: user} do
      add_room_keys_with_2_backups_to_user(user.id)

      req_body = %{"algorithm" => @algo, "auth_data" => Map.put(@auth_data, "public_key", "xyzyz")}
      conn = put(conn, ~p"/_matrix/client/v3/room_keys/version/2", req_body)

      assert %{} = response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns M_BAD_JSON (400) when the algorithm doesn't match", %{conn: conn, user: user} do
      add_room_keys_with_2_backups_to_user(user.id)

      req_body = %{"algorithm" => "org.some.other.algo", "auth_data" => Map.put(@auth_data, "public_key", "xyzyz")}
      conn = put(conn, ~p"/_matrix/client/v3/room_keys/version/2", req_body)

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 400)
      assert error =~ "algorithm needs to be one of"
    end

    test "returns M_NOT_FOUND (404) when backup doesn't exist", %{conn: conn} do
      req_body = %{"algorithm" => @algo, "auth_data" => Map.put(@auth_data, "public_key", "xyzyz")}
      conn = put(conn, ~p"/_matrix/client/v3/room_keys/version/2", req_body)

      assert %{"errcode" => "M_NOT_FOUND", "error" => "Unknown backup version"} = json_response(conn, 404)
    end

    test "returns M_INVALID_PARAM (400) when the version in the path and req body don't match", %{
      conn: conn,
      user: user
    } do
      add_room_keys_with_2_backups_to_user(user.id)

      req_body = %{"version" => "1", "algorithm" => @algo, "auth_data" => Map.put(@auth_data, "public_key", "xyzyz")}
      conn = put(conn, ~p"/_matrix/client/v3/room_keys/version/2", req_body)

      assert %{"errcode" => "M_INVALID_PARAM", "error" => "version does not match"} = json_response(conn, 400)
    end
  end

  describe "delete_backup/2" do
    test "returns an empty JSON body (200) when the backup was deleted", %{conn: conn, user: user} do
      add_room_keys_with_2_backups_to_user(user.id)

      conn = delete(conn, ~p"/_matrix/client/v3/room_keys/version/2", %{})

      assert %{} = response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns M_NOT_FOUND (404) when the backup has never existed", %{conn: conn, user: user} do
      add_room_keys_with_2_backups_to_user(user.id)

      conn = delete(conn, ~p"/_matrix/client/v3/room_keys/version/3", %{})

      assert %{"errcode" => "M_NOT_FOUND", "error" => "Unknown backup version"} = json_response(conn, 404)
    end
  end

  describe "put_keys/2" do
    @session_data %{
      "first_message_index" => 1,
      "forwarded_count" => 0,
      "is_verified" => true,
      "session_data" => %{
        "ciphertext" => "base64+ciphertext+of+JSON+data",
        "ephemeral" => "base64+ephemeral+key",
        "mac" => "base64+mac+of+ciphertext"
      }
    }

    test "successfully puts keys under a backup", %{conn: conn, user: user} do
      add_room_keys_with_2_backups_to_user(user.id)

      room_id1 = Fixtures.room_id()
      room_id2 = Fixtures.room_id()
      room_id3 = Fixtures.room_id()
      session_id1 = "abcde"
      session_id2 = "edcab"
      session_id3 = "xyzyz"

      paths = [
        ~p"/_matrix/client/v3/room_keys/keys?version=2",
        ~p"/_matrix/client/v3/room_keys/keys/#{room_id2}?version=2",
        ~p"/_matrix/client/v3/room_keys/keys/#{room_id3}/#{session_id3}?version=2"
      ]

      req_bodies = [
        %{"rooms" => %{room_id1 => %{"sessions" => %{session_id1 => @session_data}}}},
        %{"sessions" => %{session_id2 => @session_data}},
        @session_data
      ]

      for {path, req_body, i} <- Stream.zip([paths, req_bodies, 1..3]) do
        conn = put(conn, path, req_body)

        etag = "#{i}"
        assert %{"count" => ^i, "etag" => ^etag} = json_response(conn, 200)
      end
    end

    test "errors (400) when the request body is malformed", %{conn: conn} do
      conn = put(conn, ~p"/_matrix/client/v3/room_keys/keys?version=2", %{"rooms" => %{"sessions" => @session_data}})

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 400)
      assert error =~ "not of the expected shape"
    end

    test "errors (403) when the version is not the latest version", %{conn: conn} do
      req_body = %{"rooms" => %{Fixtures.room_id() => %{"sessions" => %{"abcddee" => @session_data}}}}
      conn = put(conn, ~p"/_matrix/client/v3/room_keys/keys?version=1", req_body)

      assert %{"errcode" => "M_WRONG_ROOM_KEYS_VERSION", "error" => "Cannot add keys to an old backup"} =
               json_response(conn, 403)
    end
  end

  describe "get_keys/2" do
    test "successfully fetches the desired keys", %{conn: conn, user: user} do
      room_id = Fixtures.room_id()
      session_id = "abcde"

      add_room_keys_with_2_backups_to_user(user.id)
      add_e2ee_keys_to_backup(user.id, 2, %{room_id => %{session_id => @session_data}})

      conn = get(conn, ~p"/_matrix/client/v3/room_keys/keys?version=2", %{})
      assert %{"rooms" => %{^room_id => %{"sessions" => %{^session_id => @session_data}}}} = json_response(conn, 200)

      conn = get(conn, ~p"/_matrix/client/v3/room_keys/keys/#{room_id}?version=2", %{})
      assert %{"sessions" => %{^session_id => @session_data}} = json_response(conn, 200)

      conn = get(conn, ~p"/_matrix/client/v3/room_keys/keys/#{room_id}/#{session_id}?version=2", %{})
      assert @session_data = json_response(conn, 200)
    end

    test "errors (400) when version is not provided", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v3/room_keys/keys/#{Fixtures.room_id()}/abcde", %{})
      assert %{"errcode" => "M_BAD_JSON", "error" => "'version' is required"} = json_response(conn, 400)
    end

    test "errors (404) when the given backup version is not known", %{conn: conn, user: user} do
      room_id = Fixtures.room_id()
      session_id = "abcde"

      add_room_keys_with_2_backups_to_user(user.id)
      add_e2ee_keys_to_backup(user.id, 2, %{room_id => %{session_id => @session_data}})

      conn = get(conn, ~p"/_matrix/client/v3/room_keys/keys?version=6", %{})
      assert %{"errcode" => "M_NOT_FOUND", "error" => "Unknown backup version"} = json_response(conn, 404)
    end
  end

  describe "delete_keys/2" do
    test "successfully deletes the specified keys", %{conn: conn, user: user} do
      paths =
        [
          fn _room_id, _session_id, version -> ~p"/_matrix/client/v3/room_keys/keys?version=#{version}" end,
          fn room_id, _session_id, version -> ~p"/_matrix/client/v3/room_keys/keys/#{room_id}?version=#{version}" end,
          fn room_id, session_id, version ->
            ~p"/_matrix/client/v3/room_keys/keys/#{room_id}/#{session_id}?version=#{version}"
          end
        ]
        |> Enum.shuffle()
        # all these paths hit one user, so have to make sure the backup version
        # increments for each time we call add_room_keys_with_2_backups_to_user
        |> Stream.with_index(fn _element, index -> index * 2 end)

      for {path_fxn, version} <- paths do
        room_id = Fixtures.room_id()
        session_id = Fixtures.random_string(16)
        path = path_fxn.(room_id, session_id, version)

        add_room_keys_with_2_backups_to_user(user.id)
        add_e2ee_keys_to_backup(user.id, 2, %{room_id => %{session_id => @session_data}})

        conn = delete(conn, path, %{})
        assert %{"count" => 0, "etag" => "2"} = json_response(conn, 200)
      end
    end

    test "errors (400) when version is not provided", %{conn: conn} do
      conn = delete(conn, ~p"/_matrix/client/v3/room_keys/keys/#{Fixtures.room_id()}/abcde", %{})
      assert %{"errcode" => "M_BAD_JSON", "error" => "'version' is required"} = json_response(conn, 400)
    end

    test "errors (404) when the given backup version is not known", %{conn: conn, user: user} do
      room_id = Fixtures.room_id()
      session_id = "abcde"

      add_room_keys_with_2_backups_to_user(user.id)
      add_e2ee_keys_to_backup(user.id, 2, %{room_id => %{session_id => @session_data}})

      conn = get(conn, ~p"/_matrix/client/v3/room_keys/keys?version=6", %{})
      assert %{"errcode" => "M_NOT_FOUND", "error" => "Unknown backup version"} = json_response(conn, 404)
    end
  end

  defp add_room_keys_with_2_backups_to_user(user_id) do
    {:ok, _backup} = Keys.create_room_keys_backup(user_id, @algo, @auth_data)
    {:ok, _backup} = Keys.create_room_keys_backup(user_id, @algo, @auth_data)
  end

  defp add_e2ee_keys_to_backup(user_id, version, new_room_session_backups) do
    Keys.put_room_keys_backup(user_id, version, new_room_session_backups)
  end
end
