defmodule RadioBeam.User.Authentication.LegacyAPI do
  @moduledoc """
  A minimal implementation of the [Legacy Auth
  API](https://spec.matrix.org/latest/client-server-api/#legacy-api). This
  implementation only supports registration, login, and refreshing.
  User-Interactive Authentication is not planned.
  """

  alias RadioBeam.User.Authentication.OAuth2
  alias RadioBeam.User.Database
  alias RadioBeam.User
  alias RadioBeam.User.Device

  require Logger

  def generate_device_id, do: Ecto.UUID.generate()

  @spec register(user_localpart :: String.t(), server_name :: String.t(), password :: String.t()) ::
          {:ok, User.t()} | {:error, :registration_disabled | :already_exists | Ecto.Changeset.t()}
  def register(localpart, server_name \\ RadioBeam.server_name(), password) do
    if Application.get_env(:radio_beam, :registration_enabled, false) do
      with {:ok, %User{} = user} <- User.new("@#{localpart}:#{server_name}", password),
           :ok <- Database.insert_new_user(user) do
        {:ok, user}
      end
    else
      {:error, :registration_disabled}
    end
  end

  @doc """
  Creates or refreshes a session for the given user's device if the password
  matches. The device will be created if one under the given ID doesn't
  already exist. Returns a map with an access/refresh token pair and the access
  token's expiration.
  """
  @spec password_login(User.id(), String.t(), Device.id(), String.t()) ::
          {:ok, Guardian.Token.token(), Guardian.Token.token(), String.t(), non_neg_integer()}
          | {:error, :unknown_user_or_pwd}
  def password_login(user_id, pwd, device_id, display_name) do
    code_verifier = 24 |> :crypto.strong_rand_bytes() |> Base.encode64()
    code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
    client_id = "legacy_api_client"
    redirect_uri = URI.new!("")
    scope = %{:cs_api => [:read, :write], device_id: device_id}

    grant_params = %{
      code_challenge: code_challenge,
      client_id: client_id,
      redirect_uri: redirect_uri,
      scope: scope,
      prompt: :login
    }

    case OAuth2.authenticate_user_by_password(user_id, pwd, grant_params) do
      {:ok, code} ->
        OAuth2.exchange_authz_code_for_tokens(code, code_verifier, client_id, redirect_uri, display_name: display_name)

      _ ->
        {:error, :unknown_user_or_pwd}
    end
  end

  @doc """
  Refreshes a user's session. Returns new access/refresh token information.
  """
  @spec refresh(Guardian.Token.token()) ::
          {:ok, Guardian.Token.token(), Guardian.Token.token(), scope_urns :: String.t(), non_neg_integer()}
          | {:error, any()}
  def refresh(refresh_token), do: OAuth2.refresh_token(refresh_token)

  defdelegate weak_password_message, to: OAuth2
end
