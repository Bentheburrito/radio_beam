defmodule RadioBeamWeb.AdminControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  describe "whois/2" do
    setup do
      device_display_name = "My Awesome Computer"

      %{conn: random_user_conn, account: %{user_id: random_id}} =
        RadioBeamWeb.ConnCase.setup_authenticated_user(Phoenix.ConnTest.build_conn(), %{
          device_display_name: device_display_name
        })

      # just doing this so the "last_seen_from_ip" field gets set
      get(random_user_conn, ~p"/_matrix/client/v3/capabilities", %{})

      %{device_display_name: device_display_name, random_id: random_id}
    end

    test "queries a user if the requester is an admin", %{
      conn: conn,
      account: %{user_id: admin_id},
      device_display_name: device_display_name,
      random_id: random_id
    } do
      current_admins = RadioBeam.admins()
      Application.put_env(:radio_beam, :admins, [admin_id | current_admins])

      conn = get(conn, ~p"/_matrix/client/v3/admin/whois/#{random_id}", %{})

      assert %{"user_id" => ^random_id, "devices" => devices} = json_response(conn, 200)

      assert %{
               ^device_display_name => %{
                 "sessions" => [
                   %{"connections" => [%{"ip" => "127.0.0.1", "last_seen" => _, "user_agent" => "unknown"}]}
                 ]
               }
             } = devices
    end

    test "returns M_NOT_FOUND if a user does not exist and the requester is an admin", %{
      conn: conn,
      account: %{user_id: admin_id}
    } do
      non_existing_user_id = Fixtures.user_id()

      current_admins = RadioBeam.admins()
      Application.put_env(:radio_beam, :admins, [admin_id | current_admins])

      conn = get(conn, ~p"/_matrix/client/v3/admin/whois/#{non_existing_user_id}", %{})

      assert %{"errcode" => "M_NOT_FOUND", "error" => error} = json_response(conn, 404)
      assert error =~ "user not found, or you don't have permission"
    end

    test "returns M_NOT_FOUND (404) if the requester is not an admin", %{conn: conn, random_id: random_id} do
      conn = get(conn, ~p"/_matrix/client/v3/admin/whois/#{random_id}", %{})

      assert %{"errcode" => "M_NOT_FOUND", "error" => error} = json_response(conn, 404)
      assert error =~ "user not found, or you don't have permission"
    end
  end
end
