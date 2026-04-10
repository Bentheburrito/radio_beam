defmodule RadioBeam.User.AuthenticationTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.User.Authentication

  describe "authn_and_authz_user_by_access_token/3" do
    setup %{account: %{user_id: user_id}} do
      [admin_id | _] = RadioBeam.Config.admins()
      RadioBeam.Admin.suspend_account(user_id, admin_id)
      :ok
    end

    test "allows suspended accounts that are attempting an allowed action", %{
      access_token: token,
      account: %{user_id: user_id}
    } do
      paths = [
        ["oauth2", "auth"],
        ["oauth2", "token"],
        ["_matrix", "client", "v3", "login"],
        ["_matrix", "client", "v3", "refresh"],
        ["_matrix", "client", "v3", "rooms", "!abcde", "messages"],
        ["_matrix", "client", "v3", "sync"],
        ["_matrix", "client", "v3", "sendToDevice", "abcde", "12345"],
        ["_matrix", "client", "v3", "keys", "device_signing", "upload"],
        ["_matrix", "client", "v3", "keys", "signatures", "upload"],
        ["_matrix", "client", "v3", "keys", "upload"],
        ["_matrix", "client", "v3", "room_keys", "keys"],
        ["_matrix", "client", "v3", "room_keys", "keys", "abcde"],
        ["_matrix", "client", "v3", "room_keys", "keys", "abcde", "12345"],
        ["_matrix", "client", "v3", "room_keys", "version"],
        ["_matrix", "client", "v3", "rooms", "!aabcde", "leave"],
        ["oauth2", "revoke"]
      ]

      for path_info <- paths do
        assert {:ok, ^user_id, _} =
                 Authentication.authn_and_authz_user_by_access_token(token, {127, 0, 0, 1}, path_info)
      end
    end

    test "disallows suspended accounts that are attempting an action not in the allowlist", %{access_token: token} do
      paths = [
        ["_matrix", "client", "v3", "keys", "version"],
        ["_matrix", "client", "v3", "rooms", "!aabcde", "join"],
        ["blah", "blahblah"]
      ]

      for path_info <- paths do
        assert {:error, :account_suspended} =
                 Authentication.authn_and_authz_user_by_access_token(token, {127, 0, 0, 1}, path_info)
      end
    end
  end
end
