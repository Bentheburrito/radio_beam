defmodule RadioBeam.User.AuthTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias RadioBeam.Repo
  alias RadioBeam.User
  alias RadioBeam.User.Auth
  alias RadioBeam.User.Device

  describe "password_login/3" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "returns access/refresh tokens when the given user and device exist", %{
      user: %{id: user_id} = user,
      device: %{id: device_id} = device
    } do
      assert {:ok, %User{id: ^user_id}, %Device{id: ^device_id, access_token: "" <> _, refresh_token: "" <> _}} =
               Auth.password_login(user.id, Fixtures.strong_password(), device.id, "")
    end

    test "returns access/refresh tokens when the given user exists, but the device doesn't", %{
      user: %{id: user_id} = user
    } do
      device_id = "some-user-supplied-device-id"
      display_name = "My Phone"

      assert {:ok, %User{id: ^user_id},
              %Device{id: ^device_id, access_token: "" <> _, refresh_token: "" <> _, display_name: ^display_name}} =
               Auth.password_login(user.id, Fixtures.strong_password(), device_id, display_name)
    end
  end

  describe "refresh/2" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "refreshes an existing users's existing device, returning token info", %{user: user, device: device} do
      %{refresh_token: refresh_token} = Auth.session_info(user, device)
      assert {:ok, %Device{} = device} = Auth.refresh(refresh_token)
      %{access_token: at, refresh_token: rt} = Auth.session_info(user, device)
      assert {:ok, user, device} = Auth.verify_access_token(at, {127, 0, 0, 1})
      assert %{refresh_token: ^rt} = Auth.session_info(user, device)
    end

    test "fails to refresh if the device does not have a refresh token", %{user: user} do
      device_id = Device.generate_id()
      user = User.put_device(user, Device.new(refreshable?: false, id: device_id))
      Repo.insert(user)

      refresh_token = Device.generate_token()

      logs =
        capture_log(fn ->
          assert {:error, :unknown_token} = Auth.refresh(refresh_token)
        end)

      assert logs =~ "User tried to refresh their device with an unknown refresh token"
    end

    test "fails to refresh if the device does not already exist" do
      refresh_token = Device.generate_token()

      logs =
        capture_log(fn ->
          assert {:error, :unknown_token} = Auth.refresh(refresh_token)
        end)

      assert logs =~ "User tried to refresh their device with an unknown refresh token"
    end
  end
end
