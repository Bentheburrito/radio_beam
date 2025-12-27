defmodule RadioBeam.User.Authentication.OAuth2 do
  @moduledoc """
  The main API for user authentication via OAuth 2.0. Includes a behaviour to
  interface with dedicated authorization servers.
  """
  alias RadioBeam.User
  alias RadioBeam.User.Database
  alias RadioBeam.User.LocalAccount

  @type ip_tuple() :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type code_challenge_method() :: :S256
  @type grant_type() :: :authorization_code | :refresh_token
  @type response_mode() :: :query | :fragment
  @type response_type() :: :code
  @type prompt_value() :: :create

  @type server_metadata() :: %{
          authorization_endpoint: URI.t(),
          code_challenge_methods_supported: [code_challenge_method()],
          grant_types_supported: [grant_type()],
          prompt_values_supported: [prompt_value()],
          issuer: URI.t(),
          registration_endpoint: URI.t(),
          response_modes_supported: [response_mode()],
          response_types_supported: [response_type()],
          revocation_endpoint: URI.t(),
          token_endpoint: URI.t()
        }

  @type application_type() :: :web | :native
  @type client_id() :: String.t()

  # TOIMPL: support for localized fields
  @type client_metadata() :: %{
          application_type: application_type(),
          client_id: client_id(),
          client_name: String.t(),
          client_uri: URI.t(),
          grant_types: [grant_type()],
          logo_uri: URI.t() | nil,
          policy_uri: URI.t() | nil,
          redirect_uris: [URI.t()],
          response_types: [response_type()],
          token_endpoint_auth_method: :none,
          tos_uri: URI.t() | nil
        }

  @type state() :: String.t()
  @type authz_code_grant_params() ::
          %{
            # required("client_id") => client_id(),
            # required("response_type") => response_type(),
            # required("response_mode") => response_mode(),
            # required("redirect_uri") => URI.t(),
            # required("scope") => String.t(),
            # required("state") => state(),
            # required("code_challenge") => String.t(),
            # required("code_challenge_method") => code_challenge_method()
          }

  @type authz_code() :: String.t()

  @type validated_authz_code_grant_values() :: %{
          client_id: client_id(),
          state: state(),
          redirect_uri: URI.t(),
          response_mode: response_mode(),
          code_challenge: String.t(),
          scope: map()
        }

  @callback metadata() :: server_metadata()
  @callback register_client(map()) :: client_metadata()
  @callback lookup_client(client_id()) :: client_metadata()
  @callback validate_authz_code_grant_params(authz_code_grant_params()) ::
              {:ok, validated_authz_code_grant_values()} | {:error, atom()}
  @callback authenticate_user_by_password(
              user_id :: User.id(),
              password :: String.t(),
              validated_authz_code_grant_values()
            ) ::
              {:ok, authz_code()} | {:error, :unknown_username_or_password}
  @callback exchange_authz_code_for_tokens(authz_code(), String.t(), client_id(), URI.t(), URI.t(), Keyword.t()) ::
              {:ok, Guardian.Token.token(), Guardian.Token.token(), Guardian.Token.claims(), non_neg_integer()}
              | {:error, :invalid_grant | :not_found}
  @callback authenticate_user_by_access_token(Guardian.Token.token(), ip_tuple()) ::
              {:ok, UserDeviceSession.t()} | {:error, :expired_token | :invalid_token | :not_found}
  @callback refresh_token(Guardian.Token.token()) ::
              {:ok, Guardian.Token.token(), Guardian.Token.token(), scope_urns :: String.t(), non_neg_integer()}
              | {:error, :expired_token | :invalid_token | :not_found}
  @callback revoke_token(Guardian.Token.token()) :: :ok

  def metadata(scheme \\ :https, host \\ RadioBeam.Config.server_name(), oauth2_module \\ oauth2_module())

  def metadata(scheme, host, oauth2_module) do
    base_url = "#{scheme}://#{host}"

    Map.merge(oauth2_module.metadata(), %{
      authorization_endpoint: "#{base_url}/oauth2/auth",
      issuer: "#{base_url}/",
      registration_endpoint: "#{base_url}/oauth2/clients/register",
      revocation_endpoint: "#{base_url}/oauth2/revoke",
      token_endpoint: "#{base_url}/oauth2/token"
    })
  end

  def register_client(client_metadata_attrs, oauth2_module \\ oauth2_module()) do
    oauth2_module.register_client(client_metadata_attrs)
  end

  def lookup_client(client_id, oauth2_module \\ oauth2_module()), do: oauth2_module.lookup_client(client_id)

  def validate_authz_code_grant_params(params, oauth2_module \\ oauth2_module()) do
    oauth2_module.validate_authz_code_grant_params(params)
  end

  def authenticate_user_by_password(user_id, password, code_grant_values, oauth2_module \\ oauth2_module()) do
    if code_grant_values.prompt == :create do
      with {:ok, %LocalAccount{} = user_account} <- LocalAccount.new(user_id, password),
           :ok <- Database.insert_new_user_account(user_account) do
        # temp
        {:ok, user} = User.new(user_id)
        :ok = Database.insert_new_user(user)
        # temp

        oauth2_module.authenticate_user_by_password(user_id, password, code_grant_values)
      end
    else
      oauth2_module.authenticate_user_by_password(user_id, password, code_grant_values)
    end
  end

  def exchange_authz_code_for_tokens(
        code,
        code_verifier,
        client_id,
        %URI{} = redirect_uri,
        device_opts \\ [],
        scheme \\ :https,
        host \\ RadioBeam.Config.server_name(),
        oauth2_module \\ oauth2_module()
      ) do
    issuer = URI.new!(metadata(scheme, host).issuer)
    opts = Keyword.put(device_opts, :scope_to_urn, &scope_to_urn/1)
    oauth2_module.exchange_authz_code_for_tokens(code, code_verifier, client_id, redirect_uri, issuer, opts)
  end

  def authenticate_user_by_access_token(token, ip, oauth2_module \\ oauth2_module()) do
    oauth2_module.authenticate_user_by_access_token(token, ip)
  end

  def refresh_token(refresh_token, oauth2_module \\ oauth2_module()) do
    oauth2_module.refresh_token(refresh_token)
  end

  def revoke_token(token, oauth2_module \\ oauth2_module()) do
    oauth2_module.revoke_token(token)
  end

  defp oauth2_module, do: Application.fetch_env!(:radio_beam, :oauth2_module)

  def scope_to_urn(scope) do
    Enum.map_join(scope, " ", fn
      {:device_id, device_id} -> "urn:matrix:client:device:#{device_id}"
      {:cs_api, [:read, :write]} -> "urn:matrix:client:api:*"
    end)
  end

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
