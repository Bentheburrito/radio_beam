defmodule RadioBeamWeb.LegacyAuthAPIControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Repo
  alias RadioBeam.User
  alias RadioBeam.User.Device

  describe "valid user password registration requests succeed" do
    test "with an access token and the supplied username and device ID", %{conn: conn} do
      device_id = "unrealisticallylargeiphone"
      device_display_name = "iPhone 23"
      username = "random_joe"

      conn =
        request(conn, username, %{
          "device_id" => device_id,
          "initial_device_display_name" => device_display_name
        })

      assert %{"access_token" => _, "device_id" => ^device_id, "expires_in_ms" => _, "user_id" => user_id} =
               json_response(conn, 200)

      {:ok, user} = Repo.fetch(User, user_id)
      assert {:ok, %Device{display_name: ^device_display_name}} = User.get_device(user, device_id)
      assert ^user_id = "@#{username}:localhost"
    end

    test "with an access token and the supplied username and an auto-generated device ID", %{conn: conn} do
      username = "rando"

      conn = request(conn, username)

      assert %{"access_token" => _, "device_id" => _, "expires_in_ms" => _, "user_id" => user_id} =
               json_response(conn, 200)

      assert ^user_id = "@#{username}:localhost"
    end

    test "with an access token and refresh token when the client indicates it supports refresh tokens", %{conn: conn} do
      username = "erlang-programmer"
      conn = request(conn, username, %{"refresh_token" => true})

      assert %{"access_token" => _, "refresh_token" => _, "device_id" => _, "expires_in_ms" => _, "user_id" => user_id} =
               json_response(conn, 200)

      assert ^user_id = "@#{username}:localhost"
    end

    test "without an access token or device_id when `inhibit_login` is true", %{conn: conn} do
      username = "jimothee"
      conn = request(conn, username, %{"inhibit_login" => true})

      assert %{"user_id" => user_id} = resp_body = json_response(conn, 200)
      assert ^user_id = "@#{username}:localhost"
      refute is_map_key(resp_body, "access_token")
    end
  end

  describe "valid user registration requests fail" do
    # TOIMPL: M_EXCLUSIVE test for namespaced appservice
    test "with M_USER_IN_USE when the username has been taken", %{conn: conn} do
      username = "batman"
      Fixtures.user("@#{username}:localhost")

      conn = request(conn, username)

      assert %{
               "errcode" => "M_USER_IN_USE",
               "error" => "That username is already taken."
             } = json_response(conn, 400)
    end

    test "with M_WEAK_PASSWORD (400) when the supplied password is not strong enough", %{conn: conn} do
      conn = request(conn, "dukesilver", %{"password" => "password123"})

      assert %{
               "errcode" => "M_WEAK_PASSWORD",
               "error" => error
             } = json_response(conn, 400)

      assert error =~ "include a password with at least"
    end
  end

  describe "invalid user registration requests fail" do
    test "with M_INVALID_USERNAME (400) when the username does not comply with the grammar", %{conn: conn} do
      conn = request(conn, "LOLALLCAPS")

      assert %{
               "errcode" => "M_INVALID_USERNAME",
               "error" => "localpart can only contain lowercase alphanumeric characters" <> _blahblahblah
             } = json_response(conn, 400)
    end

    test "with M_BAD_JSON when `kind` is not `user | guest`", %{conn: conn} do
      conn = request(conn, "smiley_face", %{"kind" => "wood_elf"})

      assert %{
               "errcode" => "M_BAD_JSON",
               "error" => "Expected 'user' or 'guest' as the kind, got 'wood_elf'"
             } = json_response(conn, 403)
    end
  end

  describe "login/2 - valid user password login requests succeed" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user(), "da steam deck")

      %{user: user, password: Fixtures.strong_password(), device_id: device.id}
    end

    test "with a valid user_id/password pair", %{conn: conn, user: %{id: user_id}, password: password} do
      conn = login_request(conn, user_id, password)

      assert %{
               "access_token" => _,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => _,
               "user_id" => ^user_id
             } = json_response(conn, 200)
    end

    test "with a valid localpart/password pair", %{conn: conn, user: %{id: user_id}, password: password} do
      ["@" <> localpart, _rest] = String.split(user_id, ":")

      conn = login_request(conn, localpart, password)

      assert %{
               "access_token" => _,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => _,
               "user_id" => ^user_id
             } = json_response(conn, 200)
    end

    test "with provided device parameters", %{conn: conn, user: %{id: user_id}, password: password} do
      device_id = "coolgadget"

      add_params = %{
        "device_id" => device_id,
        "display_name" => "iPhone 23X-9000"
      }

      conn = login_request(conn, user_id, password, add_params)

      assert %{
               "access_token" => _,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => ^device_id,
               "user_id" => ^user_id
             } = json_response(conn, 200)
    end

    test "with provided device parameters for an existing device", %{
      conn: conn,
      user: %{id: user_id} = user,
      password: password,
      device_id: device_id
    } do
      conn =
        login_request(conn, user_id, password, %{
          "device_id" => device_id,
          "initial_device_display_name" => "this should be ignored"
        })

      assert %{
               "access_token" => _,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => ^device_id,
               "user_id" => ^user_id
             } = json_response(conn, 200)

      {:ok, user} = Repo.fetch(User, user.id)
      {:ok, %Device{display_name: display_name}} = User.get_device(user, device_id)
      assert display_name != "this should be ignored"
    end
  end

  describe "login/2 - invalid user password login requests fail" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user(), "da steam deck")

      %{user: user, password: Fixtures.strong_password(), device_id: device.id}
    end

    test "with M_BAD_JSON when an unknown login type is provided", %{
      conn: conn,
      user: %{id: user_id},
      password: password
    } do
      device_id = "dont insert me duh"
      conn = login_request(conn, user_id, password, %{"type" => "m.wtf.are.you.high", "device_id" => device_id})

      assert %{"errcode" => "M_BAD_JSON", "error" => _} = json_response(conn, 400)
      {:ok, user} = Repo.fetch(User, user_id)
      assert {:error, :not_found} = User.get_device(user, device_id)
    end

    test "with M_FORBIDDEN when the username is incorrect", %{conn: conn, user: %{id: user_id}, password: password} do
      device_id = "dont insert me duh"
      conn = login_request(conn, "@prisonmike:localhost", password, %{"device_id" => device_id})

      assert %{"errcode" => "M_FORBIDDEN", "error" => "Unknown username or password"} = json_response(conn, 403)
      {:ok, user} = Repo.fetch(User, user_id)
      assert {:error, :not_found} = User.get_device(user, device_id)
    end

    test "with M_FORBIDDEN when the password is incorrect", %{conn: conn, user: %{id: user_id}} do
      device_id = "dont insert me duh"
      conn = login_request(conn, user_id, "justguessinghere", %{"device_id" => device_id})

      assert %{"errcode" => "M_FORBIDDEN", "error" => "Unknown username or password"} = json_response(conn, 403)
      {:ok, user} = Repo.fetch(User, user_id)
      assert {:error, :not_found} = User.get_device(user, device_id)
    end

    test "with M_BAD_JSON when an unknown identifier is provided", %{
      conn: conn,
      user: %{id: user_id},
      password: password
    } do
      device_id = "dont insert me derp"

      conn =
        login_request(conn, user_id, password, %{
          "identifier" => %{"type" => "m.wtf.are.you.drunk", "param" => "blah"},
          "device_id" => device_id
        })

      assert %{"errcode" => "M_BAD_JSON", "error" => "identifier.type needs to be one of m.id.user." <> _rest} =
               json_response(conn, 400)

      {:ok, user} = Repo.fetch(User, user_id)
      assert {:error, :not_found} = User.get_device(user, device_id)
    end
  end

  describe "refresh/2" do
    test "successfully refreshes a user's session/access token", %{
      conn: conn,
      access_token: access_token,
      refresh_token: refresh_token
    } do
      conn = post(conn, ~p"/_matrix/client/v3/refresh", %{"refresh_token" => refresh_token})

      assert %{"access_token" => at, "refresh_token" => rt, "expires_in_ms" => expires_in} = json_response(conn, 200)
      assert at != access_token
      assert rt != refresh_token
      assert is_integer(expires_in) and expires_in > 0
    end

    test "successfully repeats a refresh if the client did not apparently record the first attempt", %{
      conn: conn,
      access_token: access_token,
      refresh_token: refresh_token
    } do
      conn = post(conn, ~p"/_matrix/client/v3/refresh", %{"refresh_token" => refresh_token})

      assert %{"access_token" => at, "refresh_token" => rt} = json_response(conn, 200)
      assert at != access_token
      assert rt != refresh_token

      conn = post(conn, ~p"/_matrix/client/v3/refresh", %{"refresh_token" => refresh_token})

      assert %{"access_token" => at2, "refresh_token" => rt2} = json_response(conn, 200)

      assert at2 != at
      assert rt2 != rt
    end

    @tag :capture_log
    test "errors with M_UNKNOWN_TOKEN (401) if the refresh token is invalid", %{conn: conn} do
      conn = post(conn, ~p"/_matrix/client/v3/refresh", %{"refresh_token" => "asdfasdf123354"})

      assert %{"errcode" => "M_UNKNOWN_TOKEN", "soft_logout" => false} = json_response(conn, 401)
    end

    test "successfully refreshes a user's session/access token if the access token has expired", %{
      conn: conn,
      refresh_token: refresh_token
    } do
      {lifetime_seconds, :second} = Application.fetch_env!(:radio_beam, :access_token_lifetime)
      Process.sleep(:timer.seconds(lifetime_seconds) + 1)

      conn = post(conn, ~p"/_matrix/client/v3/refresh", %{"refresh_token" => refresh_token})

      assert %{"access_token" => _, "refresh_token" => _} = json_response(conn, 200)
    end
  end

  defp request(conn, username, add_params \\ %{}) do
    req_body =
      Map.merge(
        %{
          ### "Note that this information is not used to define how the 
          ### registered user should be authenticated, but is instead used to 
          ### authenticate the register call itself"
          # auth: %{
          #   session: "1234",
          #   type: "m.login.password"
          # },
          "username" => username,
          "password" => "Totally$trongpassword123"
        },
        add_params
      )

    post(conn, ~p"/_matrix/client/v3/register", req_body)
  end

  defp login_request(conn, user_id, password, add_params \\ %{}) do
    req_body =
      Map.merge(
        %{
          "identifier" => %{"type" => "m.id.user", "user" => user_id},
          "type" => "m.login.password",
          "password" => password
        },
        add_params
      )

    post(conn, ~p"/_matrix/client/v3/login", req_body)
  end
end
