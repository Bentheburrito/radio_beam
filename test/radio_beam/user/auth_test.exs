defmodule RadioBeam.User.AuthTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.Auth

  describe "password_login/3" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "returns access/refresh tokens when the given user and device exist", %{user: user, device: device} do
      assert {:ok, "" <> _, "" <> _, _scope, _expires_in} =
               Auth.password_login(user.id, Fixtures.strong_password(), device.id, "")
    end

    test "returns access/refresh tokens when the given user exists, but the device doesn't", %{
      user: user
    } do
      device_id = "some-user-supplied-device-id"
      display_name = "My Phone"

      assert {:ok, "" <> _ = at, "" <> _, _scope, _expires_in} =
               Auth.password_login(user.id, Fixtures.strong_password(), device_id, display_name)

      assert {:ok, %{device: %{id: ^device_id, display_name: ^display_name}}} =
               RadioBeam.OAuth2.authenticate_user_by_access_token(at, {127, 0, 0, 1})
    end
  end

  describe "refresh/2" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "refreshes an existing users's existing device, returning token info", %{user: user} do
      {:ok, _access_token, refresh_token, _claims, _expires_in} =
        Auth.password_login(user.id, Fixtures.strong_password(), Fixtures.device_id(), "")

      assert {:ok, at, rt, _, _} = Auth.refresh(refresh_token)
      assert at != rt
      assert rt != refresh_token

      assert {:ok, at, rt, _, _} = Auth.refresh(rt)
      assert at != rt
      assert rt != refresh_token
    end

    test "fails to refresh if the refresh token is invalid" do
      refresh_token = "abcde"

      assert {:error, :invalid_token} = Auth.refresh(refresh_token)
    end
  end
end
