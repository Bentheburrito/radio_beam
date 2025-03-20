defmodule RadioBeam.User.Auth do
  @moduledoc """
  Functions for authenticating users
  """

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

  @spec register(user_localpart :: String.t(), server_name :: String.t(), password :: String.t()) ::
          {:ok, User.t()} | {:error, :registration_disabled | :already_exists | Ecto.Changeset.t()}
  def register(localpart, server_name \\ RadioBeam.server_name(), password) do
    if Application.get_env(:radio_beam, :registration_enabled, false) do
      with {:ok, %User{} = user} <- User.new("@#{localpart}:#{server_name}", password) do
        User.put_new(user)
      end
    else
      {:error, :registration_disabled}
    end
  end

  @spec parse_auth_token(Device.auth_token()) ::
          {:ok, User.id(), Device.id(), Device.auth_token()} | {:error, :unknown_token}
  def parse_auth_token(token) do
    case String.split(token, ":") do
      ["@" <> localpart, servername, device_id, token] -> {:ok, "@#{localpart}:#{servername}", device_id, token}
      _ -> {:error, :unknown_token}
    end
  end

  @spec session_info(User.t(), Device.t()) :: session_info()
  def session_info(%User{} = user, %Device{} = device) do
    response = %{
      device_id: device.id,
      user_id: user.id,
      access_token: "#{user.id}:#{device.id}:#{device.access_token}",
      expires_in_ms: DateTime.diff(device.expires_at, DateTime.utc_now(), :millisecond)
    }

    if is_nil(device.refresh_token) do
      response
    else
      Map.put(response, :refresh_token, "#{user.id}:#{device.id}:#{device.refresh_token}")
    end
  end

  @doc """
  Authenticate a user by a token. Returns the authenticated user and device if
  successful, and an error tuple describing the problem with the token
  (invaild, expired) otherwise.
  """
  @spec verify_access_token(Device.auth_token()) ::
          {:ok, User.t(), Device.t()} | {:error, :expired | :unknown_token | any()}
  def verify_access_token(token) do
    Repo.one_shot(fn ->
      with {:ok, user_id, device_id, token} <- parse_auth_token(token),
           {:ok, %User{} = user} <- User.get(user_id),
           {:ok, %User{} = user, %Device{} = device} <- verify_access_token(user, device_id, token) do
        {:ok, Memento.Query.write(user), device}
      else
        {:error, :expired} -> {:error, :expired}
        _ -> {:error, :unknown_token}
      end
    end)
  end

  defp verify_access_token(user, device_id, token) do
    with {:ok, %Device{} = device} <- User.get_device(user, device_id) do
      token_matches? = Plug.Crypto.secure_compare(token, device.access_token)
      expired? = DateTime.compare(DateTime.utc_now(), device.expires_at) in [:gt, :eq]

      cond do
        expired? ->
          {:error, :expired}

        token_matches? ->
          device = put_in(device.prev_refresh_token, nil)
          {:ok, User.put_device(user, device), device}

        :else ->
          {:error, :unknown_token}
      end
    end
  end

  @doc """
  Creates or refreshes a session for the given user's device if the password
  matches. The device will be created if one under the given ID doesn't
  already exist. Returns a map with an access/refresh token pair and the access
  token's expiration.
  """
  @spec password_login(User.id(), String.t(), Device.id(), String.t()) ::
          {:ok, User.t(), Device.t()} | {:error, :unknown_user_or_pwd}
  def password_login(user_id, pwd, device_id, display_name) do
    Repo.one_shot(fn ->
      with {:ok, %User{} = user} <- User.get(user_id),
           true <- Argon2.verify_pass(pwd, user.pwd_hash) do
        device =
          case User.get_device(user, device_id) do
            {:error, :not_found} -> Device.new(id: device_id, display_name: display_name)
            {:ok, %Device{} = device} -> Device.refresh(device)
          end

        user = User.put_device(user, device)
        {:ok, Memento.Query.write(user), device}
      else
        _ -> {:error, :unknown_user_or_pwd}
      end
    end)
  end

  @doc """
  Refreshes a user's session. Returns new access/refresh token information.
  """
  @spec refresh(Device.auth_token()) :: {:ok, Device.t()} | {:error, any()}
  def refresh(refresh_token) do
    with {:ok, user_id, device_id, token} <- parse_auth_token(refresh_token),
         {:ok, %User{} = user} <- User.get(user_id),
         {:ok, %Device{} = device} <- User.get_device(user, device_id),
         {:ok, %User{} = user} <- refresh(user, device, token),
         {:ok, %User{} = user} <- Repo.one_shot(fn -> {:ok, Memento.Query.write(user)} end) do
      User.get_device(user, device.id)
    else
      {:error, error} ->
        Logger.error("User tried to refresh their device with an unknown refresh token: #{inspect(error)}")

        {:error, error}
    end
  end

  defp refresh(user, device, token) do
    refresh_match? = Plug.Crypto.secure_compare(token, device.refresh_token || "")
    prev_refresh_match? = Plug.Crypto.secure_compare(token, device.prev_refresh_token || "")

    cond do
      refresh_match? -> {:ok, User.put_device(user, Device.refresh(device))}
      # client seems to have not receieved the last refresh - don't generate new tokens
      prev_refresh_match? -> {:ok, user}
      :else -> {:error, :unknown_token}
    end
  end
end
