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

  describe "login/2" do
    test "redirects to the OAuth2 login with the expected query params", %{conn: conn} do
      conn = get(conn, ~p"/account/login", %{})
      assert redirected_to(conn) =~ "/oauth2/auth"

      assert %{
               "am_client" => "" <> _,
               "am_state" => "" <> _,
               "am_verifier" => "" <> _,
               "am_redirect_uri_str" => redirect_uri_str
             } = get_session(conn)

      assert String.ends_with?(redirect_uri_str, "/account/callback")
    end
  end

  describe "home/2" do
    setup %{conn: conn, access_token: access_token} do
      %{conn: init_test_session(conn, %{"access_token" => access_token})}
    end

    test "renders the home page of the logged in user", %{
      conn: conn,
      account: %{user_id: user_id},
      device_id: device_id
    } do
      conn = get(conn, ~p"/account", %{})

      server_name = RadioBeam.server_name()
      device_info = User.get_all_device_info(user_id)

      assert %{server_name: ^server_name, user_id: ^user_id, device_id: ^device_id, devices: ^device_info} =
               conn.assigns

      assert html = html_response(conn, 200)
      assert html =~ "Welcome #{user_id}"
    end
  end

  describe "logout/2" do
    setup %{conn: conn, access_token: access_token} do
      %{conn: init_test_session(conn, %{"access_token" => access_token})}
    end

    test "soft deletes the device, redirects to the login page, and clears the session", %{
      conn: conn,
      account: %{user_id: user_id},
      device_id: device_id
    } do
      assert user_id |> User.get_all_device_info() |> Enum.any?(&(&1.id == device_id))

      conn = post(conn, ~p"/account/logout", %{"device" => device_id})

      redir_path = redirected_to(conn)
      assert redir_path =~ "/oauth2/auth"
      refute conn |> get_session() |> is_map_key("access_token")

      conn = get(conn, redir_path, %{})
      assert html = html_response(conn, 200)
      assert html =~ "Login to your account"

      refute Enum.any?(User.get_all_device_info(user_id), &(&1.id == device_id))
    end

    test "soft deletes the target device, reloading the account homepage", %{
      conn: conn,
      account: %{user_id: user_id}
    } do
      device = Fixtures.create_device(user_id)

      assert user_id |> User.get_all_device_info() |> Enum.any?(&(&1.id == device.id))

      conn = post(conn, ~p"/account/logout", %{"device" => device.id})

      assert redirected_to(conn) == "/account"

      refute Enum.any?(User.get_all_device_info(user_id), &(&1.id == device.id))
    end
  end

  describe "update_device_name/2" do
    setup %{conn: conn, access_token: access_token} do
      %{conn: init_test_session(conn, %{"access_token" => access_token})}
    end

    test "updates the given device name", %{conn: conn, account: %{user_id: user_id}, device_id: device_id} do
      new_display_name = "my really cool device!!"

      conn =
        post(conn, ~p"/account/update_device_name", %{"device" => device_id, "new_display_name" => new_display_name})

      redir_path = redirected_to(conn)
      assert "/account" = redir_path

      conn = get(conn, redir_path, %{})

      assert html = html_response(conn, 200)
      assert html =~ "Welcome #{user_id}"
      assert html =~ new_display_name

      assert {:ok, %{display_name: ^new_display_name}} = User.get_device_info(user_id, device_id)
    end
  end

  describe "callback/2" do
    test "completes the OAuth2 login flow, saving an access token to the session", %{
      conn: conn,
      account: %{user_id: user_id}
    } do
      conn = get(conn, ~p"/account/login", %{})
      redir_path = redirected_to(conn)
      assert redir_path =~ "/oauth2/auth"

      ["@" <> localpart, _server_name] = String.split(user_id, ":")

      # fake the redirect and filling out the username/password form
      conn = get(conn, redir_path, %{})
      conn = post(conn, ~p"/oauth2/auth", %{"user_id_localpart" => localpart, "password" => Fixtures.strong_password()})

      redir_path = redirected_to(conn)
      assert redir_path =~ "/account/callback"
      conn = get(conn, redir_path, %{})

      assert %{"access_token" => "" <> _} = get_session(conn)
    end
  end

  describe "put_pusher/2" do
    test "returns an empty object (200) when setting a pusher", %{conn: conn} do
      conn =
        post(conn, ~p"/_matrix/client/v3/pushers/set", %{
          "app_display_name" => "A Company's Client",
          "app_id" => "com.a-company.client.matrix.ios",
          "data" => %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify"},
          "device_display_name" => "my iphone",
          "kind" => "http",
          "lang" => "en-US",
          "profile_tag" => "profile-tag",
          "pushkey" => "abcdefghij123"
        })

      assert %{} = response = json_response(conn, 200)
      assert 0 = map_size(response)
    end

    test "returns an M_INVALID_PARAM (400) error when setting an http pusher with an invalid or missing URL", %{
      conn: conn
    } do
      for data <- [%{}, %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify/or/what/ever"}] do
        conn =
          post(conn, ~p"/_matrix/client/v3/pushers/set", %{
            "app_display_name" => "A Company's Client",
            "app_id" => "com.a-company.client.matrix.ios",
            "data" => data,
            "device_display_name" => "my iphone",
            "kind" => "http",
            "lang" => "en-US",
            "profile_tag" => "profile-tag",
            "pushkey" => "abcdefghij123"
          })

        assert %{"errcode" => "M_INVALID_PARAM", "error" => "invalid or missing 'url' in pusher 'data'"} =
                 json_response(conn, 400)
      end
    end

    test "returns an M_INVALID_PARAM (400) error when setting invalid params", %{conn: conn} do
      for {invalid_to_merge, field_name} <- [
            {%{"app_display_name" => String.duplicate("abc", 2 ** 12)}, ":app_display_name"},
            {%{"app_id" => String.duplicate("abc", 64)}, ":app_id"},
            {%{"pushkey" => String.duplicate("abc", 512)}, ":pushkey"}
          ] do
        request_body =
          Map.merge(
            %{
              "app_display_name" => "A Company's Client",
              "app_id" => "com.a-company.client.matrix.ios",
              "data" => %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify"},
              "device_display_name" => "my iphone",
              "kind" => "http",
              "lang" => "en-US",
              "profile_tag" => "profile-tag",
              "pushkey" => "abcdefghij123"
            },
            invalid_to_merge
          )

        conn = post(conn, ~p"/_matrix/client/v3/pushers/set", request_body)

        assert %{"errcode" => "M_INVALID_PARAM", "error" => error} = json_response(conn, 400)
        assert error =~ field_name
      end
    end

    test "returns an empty object (200) when deleting a pusher", %{conn: conn, account: %{user_id: user_id}} do
      app_id = "com.a-company.client.matrix.ios"
      app_name = "A Company's Client"
      pushkey = "asdfhgahsjdf"
      data_params = %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify"}

      :ok = User.put_notification_pusher(user_id, "http", app_id, pushkey, app_name, data_params, "My iPhone")

      conn = post(conn, ~p"/_matrix/client/v3/pushers/set", %{"app_id" => app_id, "kind" => nil, "pushkey" => pushkey})

      assert %{} = response = json_response(conn, 200)
      assert 0 = map_size(response)

      assert {:ok, []} = User.get_all_notification_pushers(user_id)
    end
  end

  describe "get_pushers/2" do
    test "returns all registered pushers", %{conn: conn, account: %{user_id: user_id}} do
      conn = get(conn, ~p"/_matrix/client/v3/pushers", %{})

      assert %{"pushers" => []} = json_response(conn, 200)

      app_id = "com.a-company.client.matrix.ios"
      app_name = "A Company's Client"
      pushkey = "asdfhgahsjdf"
      data_params = %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify"}

      :ok =
        User.put_notification_pusher(user_id, "http", app_id, pushkey, app_name, data_params, "My iPhone", lang: "es")

      email_app_id = app_id <> ".email"
      email_pushkey = "someone@somewebsite.net"

      :ok =
        User.put_notification_pusher(user_id, "email", email_app_id, email_pushkey, app_name, %{}, "My iPhone",
          profile_tag: "hallo"
        )

      conn = get(conn, ~p"/_matrix/client/v3/pushers", %{})

      assert %{
               "pushers" => [
                 %{
                   "app_display_name" => ^app_name,
                   "app_id" => ^app_id,
                   "data" => ^data_params,
                   "device_display_name" => "My iPhone",
                   "kind" => "http",
                   "lang" => "es",
                   "pushkey" => ^pushkey
                 } = pusher,
                 %{
                   "app_display_name" => ^app_name,
                   "app_id" => ^email_app_id,
                   "data" => %{},
                   "device_display_name" => "My iPhone",
                   "kind" => "email",
                   "lang" => "en",
                   "profile_tag" => "hallo",
                   "pushkey" => ^email_pushkey
                 }
               ]
             } = json_response(conn, 200)

      refute is_map_key(pusher, "profile_key")
    end
  end
end
