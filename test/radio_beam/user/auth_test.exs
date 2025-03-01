defmodule RadioBeam.User.AuthTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias RadioBeam.User.Auth
  alias RadioBeam.User.Device

  describe "login/3" do
    setup do
      user = Fixtures.user()
      device = Fixtures.device(user.id)
      %{user: user, device: device}
    end

    test "returns access/refresh tokens when the given user and device exist", %{user: user, device: device} do
      assert {:ok, %{access_token: at, refresh_token: _}} = Auth.login(user.id, device.id, "")
      %{id: device_id, display_name: display_name} = device
      assert {:ok, %{id: ^device_id, display_name: ^display_name, access_token: ^at}} = Device.get(user.id, device.id)
    end

    test "returns access/refresh tokens when the given user exists, but the device doesn't", %{user: user} do
      device_id = "some-user-supplied-device-id"
      display_name = "My Phone"

      assert {:ok, %{access_token: at, refresh_token: _}} = Auth.login(user.id, device_id, display_name)
      assert {:ok, %{id: ^device_id, display_name: ^display_name, access_token: ^at}} = Device.get(user.id, device_id)
    end

    test "fails when the user does not exist" do
      user_id = "@ghostofchristmasfuture:corncob.tv"
      device_id = "asdfbasdf"
      display_name = "My Phone"

      logs =
        capture_log(fn ->
          assert {:error, :user_does_not_exist} = Auth.login(user_id, device_id, display_name)
        end)

      assert logs =~ "Error creating user device during login"
    end
  end

  describe "refresh/2" do
    setup do
      user = Fixtures.user()
      device = Fixtures.device(user.id)
      %{user: user, device: device}
    end

    test "refreshes an existing users's existing device, returning token info", %{user: user, device: device} do
      assert {:ok, %{access_token: at, refresh_token: rt}} = Auth.refresh(user.id, device.refresh_token)
      %{id: device_id, display_name: display_name} = device

      assert {:ok,
              %{
                id: ^device_id,
                display_name: ^display_name,
                access_token: ^at,
                refresh_token: ^rt,
                prev_refresh_token: prt
              }} = Device.get(user.id, device.id)

      assert at != device.access_token
      assert rt != device.refresh_token
      assert prt == device.refresh_token
    end

    test "fails to refresh if the device does not already exist", %{user: user} do
      refresh_token = "XD"

      logs =
        capture_log(fn ->
          assert {:error, :not_found} = Auth.refresh(user.id, refresh_token)
        end)

      assert logs =~ "User tried to refresh their device with an unknown refresh token"
    end

    test "fails to refresh if the user is not the owner of the device", %{device: device} do
      random_guy = Fixtures.user()

      logs =
        capture_log(fn ->
          assert {:error, :not_found} = Auth.refresh(random_guy.id, device.refresh_token)
        end)

      assert logs =~ "User tried to refresh their device with an unknown refresh token"
    end
  end
end
