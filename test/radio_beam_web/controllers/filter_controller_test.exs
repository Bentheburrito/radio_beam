defmodule RadioBeamWeb.FilterControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.Room.Timeline.Filter
  alias RadioBeam.Device
  alias RadioBeam.User
  alias RadioBeam.Repo

  setup %{conn: conn} do
    {:ok, user} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
    Repo.insert(user)

    {:ok, device} =
      Device.new(%{
        id: Device.generate_token(),
        user_id: user.id,
        display_name: "da steam deck",
        access_token: Device.generate_token(),
        refresh_token: Device.generate_token()
      })

    Repo.insert(device)

    %{conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"), user: user}
  end

  describe "put/2" do
    test "successfully puts a filter", %{conn: conn, user: %{id: user_id}} do
      req_body = %{
        "event_fields" => ["type", "content", "sender"],
        "event_format" => "client",
        "room" => %{"timeline" => %{"not_senders" => ["@spam:localhost"]}}
      }

      conn = post(conn, ~p"/_matrix/client/v3/user/#{user_id}/filter", req_body)

      assert %{"filter_id" => filter_id} = json_response(conn, 200)

      assert {:ok, %{user_id: ^user_id, definition: definition}} = Filter.get(filter_id)
      assert req_body = definition
    end

    test "cannot put a filter under another user", %{conn: conn, user: user} do
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

    test "cannot get another user's filter", %{conn: conn, user: %{id: user_id}, filter_id: filter_id} do
      conn = get(conn, ~p"/_matrix/client/v3/user/@whenami:localhost/filter/#{filter_id}")

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end
  end
end
