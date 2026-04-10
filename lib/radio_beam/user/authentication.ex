defmodule RadioBeam.User.Authentication do
  @moduledoc """
  Account authentication and authorization
  """
  alias RadioBeam.User.Authentication.OAuth2
  alias RadioBeam.User.Database
  alias RadioBeam.User.LocalAccount

  def account_suspended?(user_id) do
    case Database.fetch_user_account(user_id) do
      {:ok, %LocalAccount{} = account} -> LocalAccount.suspended?(account)
      {:error, :not_found} -> false
    end
  end

  def account_locked?(user_id) do
    case Database.fetch_user_account(user_id) do
      {:ok, %LocalAccount{} = account} -> LocalAccount.locked?(account)
      {:error, :not_found} -> false
    end
  end

  def authn_and_authz_user_by_access_token(token, ip, path_info) do
    with {:ok, user_id, device_id} <- OAuth2.authenticate_user_by_access_token(token, ip),
         :ok <- validate_unrestricted(user_id, path_info) do
      {:ok, user_id, device_id}
    end
  end

  defp validate_unrestricted(user_id, path_info) do
    with {:ok, %LocalAccount{} = account} <- Database.fetch_user_account(user_id) do
      cond do
        LocalAccount.locked?(account) -> {:error, :account_locked}
        LocalAccount.suspended?(account) and not allowed_path_info?(path_info) -> {:error, :account_suspended}
        :else -> :ok
      end
    end
  end

  # https://spec.matrix.org/v1.18/client-server-api/#account-suspension
  # Log in and create additional sessions (which are also suspended).
  defp allowed_path_info?(["oauth2", "auth"]), do: true
  defp allowed_path_info?(["oauth2", "token"]), do: true
  ## Legacy API
  defp allowed_path_info?(["_matrix", "client", "v3", "login"]), do: true
  defp allowed_path_info?(["_matrix", "client", "v3", "refresh"]), do: true
  # See and receive messages, particularly through /sync and /messages.
  defp allowed_path_info?(["_matrix", "client", "v3", "rooms", _room_id, "messages"]), do: true
  defp allowed_path_info?(["_matrix", "client", "v3", "sync"]), do: true
  # Verify other devices and write associated cross-signing data.
  defp allowed_path_info?(["_matrix", "client", "v3", "sendToDevice", _, _]), do: true
  defp allowed_path_info?(["_matrix", "client", "v3", "keys", "device_signing", "upload"]), do: true
  defp allowed_path_info?(["_matrix", "client", "v3", "keys", "signatures", "upload"]), do: true
  defp allowed_path_info?(["_matrix", "client", "v3", "keys", "upload"]), do: true
  # Populate their key backup.
  defp allowed_path_info?(["_matrix", "client", "v3", "room_keys", "keys" | _]), do: true
  defp allowed_path_info?(["_matrix", "client", "v3", "room_keys", "version"]), do: true
  # Leave rooms and reject invites.
  defp allowed_path_info?(["_matrix", "client", "v3", "rooms", _room_id, "leave"]), do: true
  # Redact their own events.
  # TODO
  # Log out or delete any device of theirs, including the current session.
  defp allowed_path_info?(["oauth2", "revoke"]), do: true
  # Deactivate their account, potentially with a time delay to discourage making a new account right away.
  # TODO
  defp allowed_path_info?(_else), do: false
end
