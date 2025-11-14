defmodule RadioBeam.User.RoomKeysTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.RoomKeys
  alias RadioBeam.User.RoomKeys.Backup

  @auth_data %{
    "public_key" => "abcdefg",
    "signatures" => %{"@alice:example.org" => %{"ed25519:deviceid" => "signature"}}
  }

  describe "new_backup/3" do
    test "creates a new key backup under a new version" do
      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert %RoomKeys{backups: backups, latest_version: 1} = room_keys
      assert 1 = map_size(backups)
      assert %{1 => %Backup{}} = backups

      room_keys = RoomKeys.new_backup(room_keys, "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert %RoomKeys{backups: backups, latest_version: 2} = room_keys
      assert 2 = map_size(backups)
      assert %{1 => %Backup{}, 2 => %Backup{}} = backups
    end

    test "errors if the algorithm isn't supported" do
      assert {:error, :unsupported_algorithm} = RoomKeys.new_backup(RoomKeys.new!(), "org.some.other.ago", @auth_data)
    end
  end

  describe "fetch_latest_backup/1" do
    test "fetches the latest backup" do
      assert {:error, :not_found} = RoomKeys.fetch_latest_backup(RoomKeys.new!())

      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert {:ok, %Backup{} = backup} = RoomKeys.fetch_latest_backup(room_keys)
      assert 1 = Backup.version(backup)

      room_keys = RoomKeys.new_backup(room_keys, "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert {:ok, %Backup{} = backup} = RoomKeys.fetch_latest_backup(room_keys)
      assert 2 = Backup.version(backup)
    end
  end

  describe "fetch_backup/2" do
    test "fetches a backup under the given version" do
      for i <- 0..4 do
        assert {:error, :not_found} = RoomKeys.fetch_backup(RoomKeys.new!(), i)
      end

      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert {:error, :not_found} = RoomKeys.fetch_backup(room_keys, 0)
      assert {:ok, %Backup{} = backup} = RoomKeys.fetch_backup(room_keys, 1)
      assert {:error, :not_found} = RoomKeys.fetch_backup(room_keys, 2)
      assert 1 = Backup.version(backup)

      room_keys = RoomKeys.new_backup(room_keys, "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert {:error, :not_found} = RoomKeys.fetch_backup(room_keys, 0)
      assert {:ok, %Backup{} = ^backup} = RoomKeys.fetch_backup(room_keys, 1)
      assert {:ok, %Backup{} = backup} = RoomKeys.fetch_backup(room_keys, 2)
      assert 2 = Backup.version(backup)
    end
  end

  describe "update_backup/4" do
    test "updates the auth_data under the backup of the given version" do
      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)
      {:ok, og_backup} = RoomKeys.fetch_latest_backup(room_keys)

      new_auth_data = Map.put(@auth_data, "public_key", "xyz")

      assert {:ok, room_keys} =
               RoomKeys.update_backup(room_keys, 1, "m.megolm_backup.v1.curve25519-aes-sha2", new_auth_data)

      {:ok, new_backup} = RoomKeys.fetch_latest_backup(room_keys)

      refute og_backup == new_backup
      assert "xyz" = new_backup.auth_data["public_key"]
    end

    test "errors when a different algorithm is given" do
      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)
      new_auth_data = Map.put(@auth_data, "public_key", "xyz")
      assert {:error, :algorithm_mismatch} = RoomKeys.update_backup(room_keys, 1, "org.another.algo", new_auth_data)
    end

    test "errors when the backup does not exist" do
      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)
      new_auth_data = Map.put(@auth_data, "public_key", "xyz")

      assert {:error, :not_found} =
               RoomKeys.update_backup(room_keys, 2, "m.megolm_backup.v1.curve25519-aes-sha2", new_auth_data)
    end
  end

  describe "delete_backup/2" do
    test "deletes the backup of a given version, or noops if it was already deleted" do
      room_keys =
        RoomKeys.new!()
        |> RoomKeys.new_backup("m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)
        |> RoomKeys.new_backup("m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert 2 = map_size(room_keys.backups)

      room_keys = RoomKeys.delete_backup(room_keys, 1)
      assert 1 = map_size(room_keys.backups)

      ^room_keys = RoomKeys.delete_backup(room_keys, 1)

      room_keys = RoomKeys.delete_backup(room_keys, 2)
      assert 0 = map_size(room_keys.backups)
    end

    test "errors if the backup never existed" do
      for i <- -1..3 do
        assert {:error, :not_found} = RoomKeys.delete_backup(RoomKeys.new!(), i)
      end
    end
  end

  @room_id1 Fixtures.room_id()
  @room_id2 Fixtures.room_id()
  @room_session_backup_attrs %{
    @room_id1 => %{
      "abcde" => %{
        "first_message_index" => 1,
        "forwarded_count" => 0,
        "is_verified" => true,
        "session_data" => %{
          "ciphertext" => "base64+ciphertext+of+JSON+data",
          "ephemeral" => "base64+ephemeral+key",
          "mac" => "base64+mac+of+ciphertext"
        }
      }
    },
    @room_id2 => %{
      "edcba" => %{
        "first_message_index" => 1,
        "forwarded_count" => 0,
        "is_verified" => true,
        "session_data" => %{
          "ciphertext" => "base64+ciphertext+of+JSON+data",
          "ephemeral" => "base64+ephemeral+key",
          "mac" => "base64+mac+of+ciphertext"
        }
      },
      "xyzyz" => %{
        "first_message_index" => 1,
        "forwarded_count" => 0,
        "is_verified" => true,
        "session_data" => %{
          "ciphertext" => "base64+ciphertext+of+JSON+data",
          "ephemeral" => "base64+ephemeral+key",
          "mac" => "base64+mac+of+ciphertext"
        }
      }
    }
  }
  describe "put_backup_keys/3" do
    test "puts more keys under the latest backup version" do
      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)
      {:ok, %Backup{} = backup} = RoomKeys.fetch_latest_backup(room_keys)
      assert 0 = Backup.count(backup)

      assert room_keys = RoomKeys.put_backup_keys(room_keys, 1, @room_session_backup_attrs)

      {:ok, %Backup{} = backup} = RoomKeys.fetch_latest_backup(room_keys)
      assert 3 = Backup.count(backup)
    end

    test "refuses to update keys for older backups" do
      room_keys =
        RoomKeys.new!()
        |> RoomKeys.new_backup("m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)
        |> RoomKeys.new_backup("m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert {:error, :wrong_room_keys_version, 2} = RoomKeys.put_backup_keys(room_keys, 1, @room_session_backup_attrs)
    end
  end

  describe "delete_backup_keys/3" do
    test "deletes all room keys under the backup for the given version" do
      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert room_keys = RoomKeys.put_backup_keys(room_keys, 1, @room_session_backup_attrs)

      {:ok, %Backup{} = backup} = RoomKeys.fetch_backup(room_keys, 1)
      assert %{@room_id1 => _, @room_id2 => _} = room_session_backups = Backup.get(backup)
      assert 2 = map_size(room_session_backups)

      assert 1 = map_size(room_keys.backups)

      room_keys = RoomKeys.delete_backup_keys(room_keys, 1)

      assert 1 = map_size(room_keys.backups)

      {:ok, %Backup{} = backup} = RoomKeys.fetch_backup(room_keys, 1)
      assert room_session_backups = Backup.get(backup)
      assert 0 = map_size(room_session_backups)
    end

    test "deletes all keys under a backup for the given version and room_id" do
      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert room_keys = RoomKeys.put_backup_keys(room_keys, 1, @room_session_backup_attrs)

      {:ok, %Backup{} = backup} = RoomKeys.fetch_backup(room_keys, 1)
      assert %{@room_id1 => _, @room_id2 => _} = room_session_backups = Backup.get(backup)
      assert 2 = map_size(room_session_backups)

      assert 1 = map_size(room_keys.backups)

      room_keys = RoomKeys.delete_backup_keys(room_keys, 1, [@room_id1])

      assert 1 = map_size(room_keys.backups)

      {:ok, %Backup{} = backup} = RoomKeys.fetch_backup(room_keys, 1)
      assert %{@room_id2 => _} = room_session_backups = Backup.get(backup)
      assert 1 = map_size(room_session_backups)
    end

    test "deletes all keys under a backup for the given version, room_id, and session_id" do
      room_keys = RoomKeys.new_backup(RoomKeys.new!(), "m.megolm_backup.v1.curve25519-aes-sha2", @auth_data)

      assert room_keys = RoomKeys.put_backup_keys(room_keys, 1, @room_session_backup_attrs)

      {:ok, %Backup{} = backup} = RoomKeys.fetch_backup(room_keys, 1)
      assert %{@room_id1 => _, @room_id2 => _} = room_session_backups = Backup.get(backup)
      assert 2 = map_size(room_session_backups)

      assert 1 = map_size(room_keys.backups)

      room_keys = RoomKeys.delete_backup_keys(room_keys, 1, [@room_id2, "edcba"])

      assert 1 = map_size(room_keys.backups)

      {:ok, %Backup{} = backup} = RoomKeys.fetch_backup(room_keys, 1)
      assert %{@room_id1 => _, @room_id2 => room_2_sessions} = room_session_backups = Backup.get(backup)
      assert 2 = map_size(room_session_backups)
      assert 1 = map_size(room_2_sessions)
      assert %{"xyzyz" => _} = room_2_sessions
    end

    test "errors when the backup version does not exist" do
      assert {:error, :not_found} = RoomKeys.delete_backup_keys(RoomKeys.new!(), 1, [@room_id2, "edcba"])
    end
  end
end
