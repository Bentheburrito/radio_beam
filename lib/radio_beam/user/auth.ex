defmodule RadioBeam.User.Auth do
  @moduledoc """
  Functions for use in the Legacy Auth API
  """

  alias RadioBeam.OAuth2
  alias RadioBeam.Repo
  alias RadioBeam.User
  alias RadioBeam.User.Device

  require Logger

  @type session_info() :: %{
          required(:access_token) => Device.auth_token(),
          required(:device_id) => Device.id(),
          required(:expires_in_ms) => non_neg_integer(),
          optional(:refresh_token) => Device.auth_token(),
          required(:user_id) => User.id()
        }

  @type ip_tuple() :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  def generate_device_id, do: Ecto.UUID.generate()

  @spec register(user_localpart :: String.t(), server_name :: String.t(), password :: String.t()) ::
          {:ok, User.t()} | {:error, :registration_disabled | :already_exists | Ecto.Changeset.t()}
  def register(localpart, server_name \\ RadioBeam.server_name(), password) do
    if Application.get_env(:radio_beam, :registration_enabled, false) do
      with {:ok, %User{} = user} <- User.new("@#{localpart}:#{server_name}", password) do
        Repo.insert_new(user)
      end
    else
      {:error, :registration_disabled}
    end
  end

  # @spec parse_auth_token(Device.auth_token()) ::
  #         {:ok, User.id(), Device.id(), Device.auth_token()} | {:error, :unknown_token}
  # def parse_auth_token(token) do
  #   case String.split(token, ":") do
  #     ["@" <> localpart, servername, device_id, token] -> {:ok, "@#{localpart}:#{servername}", device_id, token}
  #     _ -> {:error, :unknown_token}
  #   end
  # end

  # @spec session_info(User.t(), Device.t()) :: session_info()
  # def session_info(%User{} = user, %Device{} = device) do
  #   response = %{
  #     device_id: device.id,
  #     user_id: user.id,
  #     access_token: "#{user.id}:#{device.id}:#{device.access_token}",
  #     expires_in_ms: DateTime.diff(device.expires_at, DateTime.utc_now(), :millisecond)
  #   }
  #
  #   if is_nil(device.refresh_token) do
  #     response
  #   else
  #     Map.put(response, :refresh_token, "#{user.id}:#{device.id}:#{device.refresh_token}")
  #   end
  # end

  # @doc """
  # Authenticate a user by a token. Returns the authenticated user and device if
  # successful, and an error tuple describing the problem with the token
  # (invaild, expired) otherwise.
  # """
  # @spec verify_access_token(Device.auth_token(), ip_tuple()) ::
  #         {:ok, User.t(), Device.t()} | {:error, :expired | :unknown_token | any()}
  # def verify_access_token(token, device_ip_tuple) do
  #   Repo.transaction(fn ->
  #     with {:ok, user_id, device_id, token} <- parse_auth_token(token),
  #          {:ok, %User{} = user} <- Repo.fetch(User, user_id),
  #          {:ok, %User{} = user, %Device{} = device} <- verify_access_token(user, device_id, token, device_ip_tuple),
  #          {:ok, user} <- Repo.insert(user) do
  #       {:ok, user, device}
  #     else
  #       {:error, :expired} -> {:error, :expired}
  #       _ -> {:error, :unknown_token}
  #     end
  #   end)
  # end

  # defp verify_access_token(user, device_id, token, device_ip_tuple) do
  #   with {:ok, %Device{} = device} <- User.get_device(user, device_id) do
  #     token_matches? = Plug.Crypto.secure_compare(token, device.access_token)
  #     expired? = DateTime.compare(DateTime.utc_now(), device.expires_at) in [:gt, :eq]
  #
  #     cond do
  #       expired? ->
  #         {:error, :expired}
  #
  #       token_matches? ->
  #         device = device.prev_refresh_token |> put_in(nil) |> Device.put_last_seen_at(device_ip_tuple)
  #         {:ok, User.put_device(user, device), device}
  #
  #       :else ->
  #         {:error, :unknown_token}
  #     end
  #   end
  # end

  @doc """
  Creates or refreshes a session for the given user's device if the password
  matches. The device will be created if one under the given ID doesn't
  already exist. Returns a map with an access/refresh token pair and the access
  token's expiration.
  """
  @spec password_login(User.id(), String.t(), Device.id(), String.t()) ::
          {:ok, Guardian.Token.token(), Guardian.Token.token(), String.t(), non_neg_integer()}
          | {:error, :unknown_user_or_pwd}
  def password_login(user_id, pwd, device_id, _display_name) do
    code_verifier = 24 |> :crypto.strong_rand_bytes() |> Base.encode64()
    code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
    client_id = "legacy_api_client"
    redirect_uri = URI.new!("")
    scopes = %{:cs_api => [:read, :write], device_id: device_id}

    grant_params = %{
      code_challenge: code_challenge,
      client_id: client_id,
      redirect_uri: redirect_uri,
      scopes: scopes,
      prompt: :login
    }

    with {:ok, code} <- OAuth2.authenticate_user_by_password(user_id, pwd, grant_params) do
      OAuth2.exchange_authz_code_for_tokens(code, code_verifier, client_id, redirect_uri)
    else
      _ -> {:error, :unknown_user_or_pwd}
    end
  end

  @doc """
  Refreshes a user's session. Returns new access/refresh token information.
  """
  @spec refresh(Guardian.Token.token()) ::
          {:ok, Guardian.Token.token(), Guardian.Token.token(), non_neg_integer()}
          | {:error, any()}
  def refresh(refresh_token), do: OAuth2.refresh_token(refresh_token)

  # defp refresh(user, device, token) do
  #   refresh_match? = Plug.Crypto.secure_compare(token, device.refresh_token || "")
  #   prev_refresh_match? = Plug.Crypto.secure_compare(token, device.prev_refresh_token || "")
  #
  #   cond do
  #     refresh_match? -> {:ok, User.put_device(user, Device.refresh(device))}
  #     # client seems to have not receieved the last refresh - don't generate new tokens
  #     prev_refresh_match? -> {:ok, user}
  #     :else -> {:error, :unknown_token}
  #   end
  # end

  def weak_password_message do
    """
    Please include a password with at least:

    - 1 uppercase letter
    - 1 lowercase letter
    - 1 special character of the following: !@#$%^&*()_-+={[}]|\:;"'<,>.?/
    - 1 number
    - 8 characters total
    """
  end
end
