defmodule RadioBeam.User.Database do
  @moduledoc """
  A behaviour for implementing a persistence backend for the `RadioBeam.User`
  bounded context.
  """
  alias RadioBeam.User
  alias RadioBeam.User.Authentication.OAuth2
  alias RadioBeam.User.Authentication.OAuth2.Builtin.DynamicOAuth2Client
  alias RadioBeam.User.Device

  @type return_value() :: term()

  @callback insert_new_user_account(LocalAccount.t()) :: :ok | {:error, :already_exists}
  @callback fetch_user_account(User.id()) :: {:ok, LocalAccount.t()} | {:error, :not_found}
  @callback insert_new_device(Device.t()) :: :ok | {:error, :already_exists}
  @callback update_user_device_with(User.id(), Device.id(), (Device.t() ->
                                                               {:ok, Device.t()}
                                                               | {:ok, Device.t(), return_value()}
                                                               | {:error, term()})) ::
              {:ok, Device.t()} | {:ok, return_value()} | {:error, term()}
  @callback fetch_user_device(User.id(), Device.id()) :: {:ok, Device.t()} | {:error, :not_found}
  @callback get_all_devices_of_user(User.id()) :: [Device.t()]
  @callback upsert_oauth2_client(DynamicOAuth2Client.t()) :: :ok
  @callback fetch_oauth2_client(OAuth2.client_id()) :: {:ok, DynamicOAuth2Client.t()} | {:error, :not_found}

  # deprecated
  @callback insert_new_user(User.t()) :: :ok | {:error, :already_exists}
  @callback fetch_user(User.id()) :: {:ok, User.t()} | {:error, :not_found}
  @callback update_user(User.t()) :: :ok | {:error, :not_found}

  # temp, should be able to update devices and things directly
  @callback with_user(User.id(), (User.t() -> term())) :: term()
  @callback with_all_users([User.id()], ([User.t()] -> term())) :: term()
  @callback txn((-> term())) :: term()

  @database_backend Application.compile_env!(:radio_beam, [RadioBeam.User.Database, :backend])
  defdelegate insert_new_user_account(user_account), to: @database_backend
  defdelegate fetch_user_account(user_id), to: @database_backend
  defdelegate insert_new_device(device), to: @database_backend
  defdelegate update_user_device_with(user_id, device_id, callback), to: @database_backend
  defdelegate fetch_user_device(user_id, device_id), to: @database_backend
  defdelegate get_all_devices_of_user(user_id), to: @database_backend
  defdelegate upsert_oauth2_client(oauth2_client_metadata), to: @database_backend
  defdelegate fetch_oauth2_client(client_id), to: @database_backend

  # deprecated
  defdelegate insert_new_user(user), to: @database_backend
  defdelegate update_user(user), to: @database_backend
  defdelegate fetch_user(user_id), to: @database_backend

  # temp, should be able to update devices and things directly
  defdelegate with_user(user_id, callback), to: @database_backend
  defdelegate with_all_users(user_ids, callback), to: @database_backend
  defdelegate txn(callback), to: @database_backend
end
