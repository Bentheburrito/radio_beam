defmodule RadioBeamWeb.AuthControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.{Device, Repo, User}

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

      assert {:ok, %Device{display_name: ^device_display_name}} = Repo.get(Device, device_id)
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
      {:ok, user} = User.new("@#{username}:localhost", "B4tm2n!1")
      Repo.insert!(user)

      conn = request(conn, username)

      assert %{
               "errcode" => "M_USER_IN_USE",
               "error" => "That username is already taken."
             } = json_response(conn, 400)
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
end
