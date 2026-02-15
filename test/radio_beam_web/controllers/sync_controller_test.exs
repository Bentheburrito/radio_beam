defmodule RadioBeamWeb.SyncControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Room
  alias RadioBeam.Sync.NextBatch
  alias RadioBeam.User

  setup do
    %{creator: Fixtures.create_account()}
  end

  @otk_keys %{
    "signed_curve25519:AAAAHQ" => %{
      "key" => "key1",
      "signatures" => %{
        "@alice:example.com" => %{
          "ed25519:JLAFKJWSCS" =>
            "IQeCEPb9HFk217cU9kw9EOiusC6kMIkoIRnbnfOh5Oc63S1ghgyjShBGpu34blQomoalCyXWyhaaT3MrLZYQAA"
        }
      }
    },
    "signed_curve25519:AAAAHg" => %{
      "key" => "key2",
      "signatures" => %{
        "@alice:example.com" => %{
          "ed25519:JLAFKJWSCS" =>
            "FLWxXqGbwrb8SM3Y795eB6OA8bwBcoMZFXBqnTn58AYWZSqiD45tlBVcDa2L7RwdKXebW/VzDlnfVJ+9jok1Bw"
        }
      }
    }
  }
  @fallback_key %{
    "signed_curve25519:AAAAGj" => %{
      "fallback" => true,
      "key" => "fallback1",
      "signatures" => %{
        "@alice:example.com" => %{
          "ed25519:JLAFKJWSCS" =>
            "FLWxXqGbwrb8SM3Y795eB6OA8bwBcoMZFXBqnTn58AYWZSqiD45tlBVcDa2L7RwdKXebW/VzDlnfVJ+9jok1Bw"
        }
      }
    }
  }
  describe "sync/2" do
    test "successfully syncs with a room", %{conn: conn, creator: creator, account: account, device_id: device_id} do
      conn = get(conn, ~p"/_matrix/client/v3/sync", %{})

      assert %{"account_data" => account_data, "next_batch" => since} = response = json_response(conn, 200)
      refute is_map_key(response, "rooms")

      assert 0 = map_size(account_data)

      # ---

      {:ok, room_id1} = Room.create(creator.user_id, name: "name one")
      {:ok, _event_id} = Room.invite(room_id1, creator.user_id, account.user_id)
      :ok = User.put_account_data(account.user_id, :global, "m.some_config", %{"hello" => "world"})
      :ok = User.put_account_data(account.user_id, room_id1, "m.some_config", %{"hello" => "room"})

      User.send_to_devices(
        %{account.user_id => %{device_id => %{"hello" => "world"}}},
        "@hello:world",
        "com.spectrum.corncobtv.new_release"
      )

      conn = get(conn, ~p"/_matrix/client/v3/sync?since=#{since}", %{})

      assert %{
               "account_data" => account_data,
               "to_device" => %{"events" => [%{"content" => %{"hello" => "world"}}]},
               "rooms" =>
                 %{
                   "invite" => %{^room_id1 => %{"invite_state" => %{"events" => invite_state}}}
                 } = rooms,
               "next_batch" => since
             } = json_response(conn, 200)

      refute is_map_key(rooms, "join")
      refute is_map_key(rooms, "leave")

      user_id = account.user_id

      assert 4 = length(invite_state)
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.name"}, &1))
      assert Enum.any?(invite_state, &match?(%{"type" => "m.room.member", "state_key" => ^user_id}, &1))

      assert 1 = map_size(account_data)
      assert %{"m.some_config" => %{"hello" => "world"}} = account_data

      # ---

      creator_device = Fixtures.create_device(creator.user_id)
      Fixtures.create_and_put_device_keys(creator.user_id, creator_device.id)

      {:ok, _event_id} = Room.join(room_id1, account.user_id)
      {:ok, _event_id} = Room.set_name(room_id1, creator.user_id, "yo")

      User.send_to_devices(
        %{account.user_id => %{device_id => %{"hello" => "world"}}},
        "@hello:world",
        "com.spectrum.corncobtv.new_release"
      )

      User.send_to_devices(
        %{account.user_id => %{device_id => %{"hello2" => "world"}}},
        "@hello:world",
        "com.spectrum.corncobtv.notification"
      )

      {:ok, _otk_counts} =
        User.put_device_keys(account.user_id, device_id, one_time_keys: @otk_keys, fallback_keys: @fallback_key)

      filter = JSON.encode!(%{"room" => %{"timeline" => %{"limit" => 3}}})

      creator_id = creator.user_id

      conn = get(conn, ~p"/_matrix/client/v3/sync?since=#{since}&filter=#{filter}", %{})

      assert %{
               "account_data" => account_data,
               "to_device" => %{
                 "events" => [%{"content" => %{"hello" => "world"}}, %{"content" => %{"hello2" => "world"}}]
               },
               "device_one_time_keys_count" => %{"signed_curve25519" => 2},
               "device_unused_fallback_key_types" => ["signed_curve25519"],
               "device_lists" => %{"changed" => [^creator_id], "left" => []},
               "rooms" =>
                 %{
                   "join" => %{
                     ^room_id1 => %{
                       "account_data" => room_account_data,
                       # "state" => %{"events" => []},
                       "state" => %{"events" => state_events},
                       "timeline" => timeline
                     }
                   }
                 } = rooms,
               "next_batch" => _since
             } = json_response(conn, 200)

      refute is_map_key(rooms, "invite")
      refute is_map_key(rooms, "leave")

      assert 7 = length(state_events)

      user_id = account.user_id

      assert %{
               # "limited" => false,
               "limited" => true,
               "prev_batch" => _,
               "events" => [
                 %{"type" => "m.room.member", "content" => %{"membership" => "invite"}, "sender" => ^creator_id},
                 %{"type" => "m.room.member", "content" => %{"membership" => "join"}, "sender" => ^user_id},
                 %{"type" => "m.room.name", "content" => %{"name" => "yo"}}
               ]
             } =
               timeline

      assert %{"m.some_config" => %{"hello" => "world"}} = account_data
      assert %{"m.some_config" => %{"hello" => "room"}} = room_account_data
    end
  end

  describe "get_messages/2" do
    test "successfully fetches events when user is a member of the room", %{conn: conn, account: creator} do
      {:ok, room_id} = Room.create(creator.user_id, name: "This is a cool room")

      {:ok, _event_id} =
        Room.send(room_id, creator.user_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "this place is so cool"
        })

      query_params = %{
        filter: %{"limit" => 3},
        dir: "b"
      }

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/messages?#{query_params}", %{})

      assert %{"chunk" => chunk, "end" => next, "start" => _, "state" => state} =
               json_response(conn, 200)

      assert 1 = length(state)
      assert [%{"content" => %{"body" => "this place is so cool"}}, %{"type" => "m.room.name"}, _] = chunk

      query_params = %{
        filter: %{"limit" => 3},
        dir: "b",
        from: next
      }

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/messages?#{query_params}", %{})

      assert %{"chunk" => chunk, "end" => _next2, "start" => next2, "state" => state} =
               json_response(conn, 200)

      {:ok, next} = NextBatch.decode(next)
      {:ok, next2} = NextBatch.decode(next2)
      assert NextBatch.topologically_equal?(next, next2)

      assert 1 = length(state)
      assert [%{"type" => "m.room.history_visibility"}, %{"type" => "m.room.join_rules"}, _] = chunk
    end

    test "fails with M_FORBIDDEN (403) when the room doesn't exist or the requester isn't currently in it", %{
      conn: conn,
      creator: creator
    } do
      {:ok, room_id} = Room.create(creator.user_id, name: "This is a cool room")

      query_params = %{
        dir: "b"
      }

      conn = get(conn, ~p"/_matrix/client/v3/rooms/#{room_id}/messages?#{query_params}", %{})

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end
end
