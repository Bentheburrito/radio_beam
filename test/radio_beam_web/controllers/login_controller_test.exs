defmodule RadioBeamWeb.LoginControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.Device

  setup_all do
    %{id: user_id} = Fixtures.user()
    device = Fixtures.device(user_id, "da steam deck")

    %{user_id: user_id, password: Fixtures.strong_password(), access_token: device.access_token, device_id: device.id}
  end

  describe "valid user password login requests succeed" do
    test "with a valid user_id/password pair", %{conn: conn, user_id: user_id, password: password} do
      conn = request(conn, user_id, password)

      assert %{
               "access_token" => _,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => _,
               "user_id" => ^user_id
             } = json_response(conn, 200)
    end

    test "with a valid localpart/password pair", %{conn: conn, user_id: user_id, password: password} do
      ["@" <> localpart, _rest] = String.split(user_id, ":")

      conn = request(conn, localpart, password)

      assert %{
               "access_token" => _,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => _,
               "user_id" => ^user_id
             } = json_response(conn, 200)
    end

    test "with provided device parameters", %{conn: conn, user_id: user_id, password: password} do
      device_id = "coolgadget"

      add_params = %{
        "device_id" => device_id,
        "display_name" => "iPhone 23X-9000"
      }

      conn = request(conn, user_id, password, add_params)

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
      user_id: user_id,
      password: password,
      device_id: device_id
    } do
      conn =
        request(conn, user_id, password, %{
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

      {:ok, %Device{display_name: display_name}} = Device.get(user_id, device_id)
      assert display_name != "this should be ignored"
    end
  end

  describe "invalid user password login requests fail" do
    test "with M_BAD_JSON when an unknown login type is provided", %{conn: conn, user_id: user_id, password: password} do
      device_id = "dont insert me duh"
      conn = request(conn, user_id, password, %{"type" => "m.wtf.are.you.high", "device_id" => device_id})

      assert %{"errcode" => "M_BAD_JSON", "error" => _} = json_response(conn, 400)
      assert {:error, :not_found} = Device.get(user_id, device_id)
    end

    test "with M_FORBIDDEN when the username is incorrect", %{conn: conn, user_id: user_id, password: password} do
      device_id = "dont insert me duh"
      conn = request(conn, "@prisonmike:localhost", password, %{"device_id" => device_id})

      assert %{"errcode" => "M_FORBIDDEN", "error" => "Unknown username or password"} = json_response(conn, 403)
      assert {:error, :not_found} = Device.get(user_id, device_id)
    end

    test "with M_FORBIDDEN when the password is incorrect", %{conn: conn, user_id: user_id} do
      device_id = "dont insert me duh"
      conn = request(conn, user_id, "justguessinghere", %{"device_id" => device_id})

      assert %{"errcode" => "M_FORBIDDEN", "error" => "Unknown username or password"} = json_response(conn, 403)
      assert {:error, :not_found} = Device.get(user_id, device_id)
    end

    test "with M_BAD_JSON when an unknown identifier is provided", %{conn: conn, user_id: user_id, password: password} do
      device_id = "dont insert me derp"

      conn =
        request(conn, user_id, password, %{
          "identifier" => %{"type" => "m.wtf.are.you.drunk", "param" => "blah"},
          "device_id" => device_id
        })

      assert %{"errcode" => "M_BAD_JSON", "error" => "Unrecognized or missing 'identifier'" <> _rest} =
               json_response(conn, 400)

      assert {:error, :not_found} = Device.get(user_id, device_id)
    end
  end

  defp request(conn, user_id, password, add_params \\ %{}) do
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
