defmodule RadioBeamWeb.HomeserverInfoControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  @expected_keys ~w|m.change_password m.room_versions m.set_displayname m.set_avatar_url m.3pid_changes|

  test "home/2", %{conn: conn} do
    conn = get(conn, ~p"/", %{})
    assert "RadioBeam is up and running 🎉" = response(conn, 200)
  end

  test "capabilities/2", %{conn: conn} do
    conn = get(conn, ~p"/_matrix/client/v3/capabilities", %{})
    assert %{"capabilities" => caps} = json_response(conn, 200)
    for key <- @expected_keys, do: assert(is_map_key(caps, key))
  end

  test "versions/2", %{conn: conn} do
    conn = get(conn, ~p"/_matrix/client/versions", %{})
    assert %{"versions" => versions} = json_response(conn, 200)
    assert is_list(versions)
  end

  test "login_types/2", %{conn: conn} do
    conn = get(conn, ~p"/_matrix/client/v3/login", %{})
    assert %{"flows" => [%{"type" => "m.login.password"}]} = json_response(conn, 200)
  end

  test "well_known_client/2", %{conn: conn} do
    conn = get(conn, ~p"/.well-known/matrix/client", %{})
    assert %{"m.homeserver" => _} = json_response(conn, 200)
  end
end
