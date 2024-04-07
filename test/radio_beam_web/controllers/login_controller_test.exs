defmodule RadioBeamWeb.LoginControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.{Device, Repo, User}

  setup_all do
    user_id =
      "@danflahes_employee_#{Enum.random(0..9_999_999_999_999)}:#{Application.get_env(:radio_beam, :server_name)}"

    password = 16 |> :crypto.strong_rand_bytes() |> Base.encode64()

    {:ok, user} = User.new(user_id, password)
    Repo.insert(user)

    {:ok, device} =
      Device.new(%{
        id: Device.generate_token(),
        user_id: user_id,
        display_name: "da steam deck",
        access_token: Device.generate_token(),
        refresh_token: Device.generate_token()
      })

    Repo.insert(device)

    %{user_id: user_id, password: password, device: device}
  end

  describe "valid user password login requests succeed" do
    test "with a valid user_id/password pair", %{conn: conn, user_id: user_id, password: password} do
      conn = request(conn, user_id, password)

      assert %{
               "access_token" => at,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => device_id,
               "user_id" => ^user_id
             } = json_response(conn, 200)

      assert {:ok, %Device{access_token: ^at}} = Repo.get(Device, device_id)
    end

    test "with a valid localpart/password pair", %{conn: conn, user_id: user_id, password: password} do
      ["@" <> localpart, _rest] = String.split(user_id, ":")

      conn = request(conn, localpart, password)

      assert %{
               "access_token" => at,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => device_id,
               "user_id" => ^user_id
             } = json_response(conn, 200)

      assert {:ok, %Device{access_token: ^at}} = Repo.get(Device, device_id)
    end

    test "with provided device parameters", %{conn: conn, user_id: user_id, password: password} do
      add_params = %{
        "device_id" => "coolgadget",
        "display_name" => "iPhone 23X-9000"
      }

      conn = request(conn, user_id, password, add_params)

      assert %{
               "access_token" => at,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => device_id,
               "user_id" => ^user_id
             } = json_response(conn, 200)

      assert {:ok, %Device{access_token: ^at}} = Repo.get(Device, device_id)
    end

    test "with provided device parameters for an existing device", %{
      conn: conn,
      user_id: user_id,
      password: password,
      device: %Device{id: device_id}
    } do
      conn =
        request(conn, user_id, password, %{
          "device_id" => device_id,
          "initial_device_display_name" => "this should be ignored"
        })

      assert %{
               "access_token" => at,
               "refresh_token" => _,
               "expires_in_ms" => _,
               "device_id" => ^device_id,
               "user_id" => ^user_id
             } = json_response(conn, 200)

      assert {:ok, %Device{display_name: "da steam deck", access_token: ^at}} = Repo.get(Device, device_id)
    end
  end

  describe "invalid user password login requests fail" do
    test "with M_BAD_JSON when an unknown login type is provided", %{conn: conn, user_id: user_id, password: password} do
      device_id = "dont insert me duh"
      conn = request(conn, user_id, password, %{"type" => "m.wtf.are.you.high", "device_id" => device_id})

      assert %{"errcode" => "M_BAD_JSON", "error" => _} = json_response(conn, 400)
      assert {:ok, nil} = Repo.get(Device, device_id)
    end

    test "with M_FORBIDDEN when the username is incorrect", %{conn: conn, password: password} do
      device_id = "dont insert me duh"
      conn = request(conn, "@prisonmike:localhost", password, %{"device_id" => device_id})

      assert %{"errcode" => "M_FORBIDDEN", "error" => "Unknown username or password"} = json_response(conn, 403)
      assert {:ok, nil} = Repo.get(Device, device_id)
    end

    test "with M_FORBIDDEN when the password is incorrect", %{conn: conn, user_id: user_id} do
      device_id = "dont insert me duh"
      conn = request(conn, user_id, "justguessinghere", %{"device_id" => device_id})

      assert %{"errcode" => "M_FORBIDDEN", "error" => "Unknown username or password"} = json_response(conn, 403)
      assert {:ok, nil} = Repo.get(Device, device_id)
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

      assert {:ok, nil} = Repo.get(Device, device_id)
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
