defmodule RadioBeamWeb.AuthControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.{Device, Repo, User}
  alias RadioBeamWeb.AuthController

  describe "valid user password registration requests succeed" do
    defp request(username) do
      %{
        ### "Note that this information is not used to define how the registered user should be authenticated, but is instead used to authenticate the register call itself"
        # auth: %{
        #   session: "1234",
        #   type: "m.login.password"
        # },
        "username" => username,
        "password" => "Totally$trongpassword123"
      }
    end

    test "with an access token and the supplied username and device ID", %{conn: conn} do
      device_id = "unrealisticallylargeiphone"
      device_display_name = "iPhone 23"
      username = "random_joe"

      resp =
        AuthController.register(
          conn,
          request(username)
          |> Map.put("device_id", device_id)
          |> Map.put("initial_device_display_name", device_display_name)
        )

      assert %{access_token: _, device_id: ^device_id, expires_in_ms: _, user_id: user_id} =
               Jason.decode!(resp.resp_body, keys: :atoms)

      assert {:ok, %Device{display_name: ^device_display_name}} = Repo.get(Device, device_id)
      assert ^user_id = "@#{username}:localhost"
      assert 200 = resp.status
    end

    test "with an access token and the supplied username and an auto-generated device ID", %{conn: conn} do
      username = "rando"
      resp = AuthController.register(conn, request(username))

      assert %{access_token: _, device_id: _, expires_in_ms: _, user_id: user_id} =
               Jason.decode!(resp.resp_body, keys: :atoms)

      assert ^user_id = "@#{username}:localhost"
      assert 200 = resp.status
    end

    test "with an access token and refresh token when the client indicates it supports refresh tokens", %{conn: conn} do
      username = "erlang-programmer"
      resp = AuthController.register(conn, Map.put(request(username), "refresh_token", true))

      assert %{access_token: _, refresh_token: _, device_id: _, expires_in_ms: _, user_id: user_id} =
               Jason.decode!(resp.resp_body, keys: :atoms)

      assert ^user_id = "@#{username}:localhost"
      assert 200 = resp.status
    end

    test "without an access token or device_id when `inhibit_login` is true", %{conn: conn} do
      username = "jimothee"
      resp = AuthController.register(conn, Map.put(request(username), "inhibit_login", true))

      assert %{"user_id" => user_id} = resp_body = Jason.decode!(resp.resp_body)
      assert ^user_id = "@#{username}:localhost"
      refute is_map_key(resp_body, "access_token")
      assert 200 = resp.status
    end
  end

  describe "valid user registration requests fail" do
    # TOIMPL: M_EXCLUSIVE test for namespaced appservice
    test "with M_USER_IN_USE when the username has been taken", %{conn: conn} do
      username = "batman"
      {:ok, user} = User.new("@#{username}:localhost", "B4tm2n!1")
      Repo.insert!(user)

      resp = AuthController.register(conn, request(username))

      assert %{
               errcode: "M_USER_IN_USE",
               error: "That username is already taken."
             } = Jason.decode!(resp.resp_body, keys: :atoms)

      assert 400 = resp.status
    end
  end

  describe "invalid user registration requests fail" do
    test "with M_INVALID_USERNAME (400) when the username does not comply with the grammar", %{conn: conn} do
      resp = AuthController.register(conn, request("LOLALLCAPS"))

      assert %{
               errcode: "M_INVALID_USERNAME",
               error: "localpart can only contain lowercase alphanumeric characters" <> _blahblahblah
             } = Jason.decode!(resp.resp_body, keys: :atoms)

      assert 400 = resp.status
    end

    test "with M_BAD_JSON when `kind` is not `user | guest`", %{conn: conn} do
      resp = AuthController.register(conn, Map.put(request("smiley_face"), "kind", "wood_elf"))

      assert %{
               errcode: "M_BAD_JSON",
               error: "Expected 'user' or 'guest' as the kind, got 'wood_elf'"
             } = Jason.decode!(resp.resp_body, keys: :atoms)
    end
  end
end
