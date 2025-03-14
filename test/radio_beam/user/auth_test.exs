defmodule RadioBeam.User.AuthTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias RadioBeam.User
  alias RadioBeam.User.Auth
  alias RadioBeam.User.Device

  describe "login/3" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "returns access/refresh tokens when the given user and device exist", %{user: user, device: device} do
      assert %{access_token: at, refresh_token: _} = Auth.upsert_device_session(user, device.id, "")
      %{id: device_id, display_name: display_name} = device
      {:ok, user} = User.get(user.id)
      assert {:ok, %{id: ^device_id, display_name: ^display_name, access_token: ^at}} = Device.get(user, device.id)
    end

    test "returns access/refresh tokens when the given user exists, but the device doesn't", %{user: user} do
      device_id = "some-user-supplied-device-id"
      display_name = "My Phone"

      assert %{access_token: at, refresh_token: _} = Auth.upsert_device_session(user, device_id, display_name)
      {:ok, user} = User.get(user.id)
      assert {:ok, %{id: ^device_id, display_name: ^display_name, access_token: ^at}} = Device.get(user, device_id)
    end
  end

  describe "refresh/2" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "refreshes an existing users's existing device, returning token info", %{user: user, device: device} do
      assert {:ok, %{access_token: at, refresh_token: rt}} = Auth.refresh(device.refresh_token)
      %{id: device_id, display_name: display_name} = device
      {:ok, user} = User.get(user.id)

      assert {:ok,
              %{
                id: ^device_id,
                display_name: ^display_name,
                access_token: ^at,
                refresh_token: ^rt,
                prev_refresh_token: prt
              }} = Device.get(user, device.id)

      assert at != device.access_token
      assert rt != device.refresh_token
      assert prt == device.refresh_token
    end

    test "fails to refresh if the device does not have a refresh token", %{user: user} do
      device_id = Device.generate_id()
      user = Device.new(user, refreshable?: false, id: device_id)
      Memento.transaction!(fn -> Memento.Query.write(user) end)

      refresh_token = Device.generate_token(user.id, device_id)

      logs =
        capture_log(fn ->
          assert {:error, :unknown_token} = Auth.refresh(refresh_token)
        end)

      assert logs =~ "User tried to refresh their device with an unknown refresh token"
    end

    test "fails to refresh if the device does not already exist", %{user: user} do
      refresh_token = Device.generate_token(user.id, Device.generate_id())

      logs =
        capture_log(fn ->
          assert {:error, :unknown_token} = Auth.refresh(refresh_token)
        end)

      assert logs =~ "User tried to refresh their device with an unknown refresh token"
    end
  end
end
