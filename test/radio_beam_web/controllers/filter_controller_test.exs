defmodule RadioBeamWeb.FilterControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Room.Timeline.Filter

  setup %{conn: conn} do
    user = Fixtures.user()
    device = Fixtures.device(user.id)

    %{conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"), user: user}
  end

  describe "put/2" do
    test "successfully puts a filter", %{conn: conn, user: %{id: user_id}} do
      req_body = %{
        "event_fields" => ["type", "content", "sender"],
        "event_format" => "client",
        "room" => %{"timeline" => %{"not_senders" => ["@spam:localhost"], "rooms" => ["!asdf:localhost"]}}
      }

      conn = post(conn, ~p"/_matrix/client/v3/user/#{user_id}/filter", req_body)

      assert %{"filter_id" => filter_id} = json_response(conn, 200)

      assert {:ok, %{user_id: ^user_id, definition: definition}} = Filter.get(filter_id)

      assert %{
               "event_fields" => ["type", "content", "sender"],
               "event_format" => "client",
               "room" => %{"timeline" => %{"not_senders" => ["@spam:localhost"]}}
             } = definition
    end

    test "cannot put a filter under another user", %{conn: conn} do
      req_body = %{
        "event_fields" => ["type", "content", "sender"],
        "event_format" => "client",
        "room" => %{"timeline" => %{"not_senders" => ["@spam:localhost"]}}
      }

      conn = post(conn, ~p"/_matrix/client/v3/user/@whoami:localhost/filter", req_body)

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end

  describe "get/1" do
    setup %{user: %{id: user_id}} do
      {:ok, filter_id} =
        Filter.put(user_id, %{
          "event_fields" => ["type", "content", "sender"],
          "event_format" => "client",
          "room" => %{"timeline" => %{"not_senders" => ["@spam:localhost"]}}
        })

      %{filter_id: filter_id}
    end

    test "can retrive a user's previously put filter by ID", %{conn: conn, user: %{id: user_id}, filter_id: filter_id} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/filter/#{filter_id}")

      assert %{"room" => %{"timeline" => %{"not_senders" => ["@spam:localhost"]}}} = json_response(conn, 200)
    end

    test "cannot get another user's filter", %{conn: conn, filter_id: filter_id} do
      conn = get(conn, ~p"/_matrix/client/v3/user/@whenami:localhost/filter/#{filter_id}")

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "returns M_NOT_FOUND when no filter is known under the given ID", %{conn: conn, user: %{id: user_id}} do
      conn = get(conn, ~p"/_matrix/client/v3/user/#{user_id}/filter/whatava")

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end
  end
end
