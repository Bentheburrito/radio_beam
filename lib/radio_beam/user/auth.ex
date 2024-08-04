defmodule RadioBeam.User.Auth do
  alias RadioBeam.Device
  alias RadioBeam.User

  require Logger

  @type auth_info :: %{
          required(:access_token) => String.t(),
          required(:refresh_token) => String.t(),
          required(:expires_in_ms) => non_neg_integer()
        }

  @type token_type :: :access | :refresh

  @doc """
  Authenticate a user by a token.
  """
  @spec by(token_type(), token :: String.t()) ::
          {:ok, User.t(), Device.t()} | {:error, :expired | :unknown_token | any()}
  def by(:access, at), do: get_user_and_device(fn -> Device.select_by_access_token(at) end, true)
  def by(:refresh, rt), do: get_user_and_device(fn -> Device.select_by_refresh_token(rt) end, false)

  defp get_user_and_device(selector, upkeep?) do
    fn ->
      with %Device{} = device <- selector.(),
           :lt <- DateTime.compare(DateTime.utc_now(), device.expires_at) do
        %User{} = user = Memento.Query.read(User, device.user_id)
        %Device{} = device = if upkeep?, do: Device.upkeep(device), else: device

        {user, device}
      else
        :none -> :unknown_token
        compare_result when compare_result in [:eq, :gt] -> :expired
      end
    end
    |> Memento.transaction()
    |> case do
      {:ok, {user, device}} -> {:ok, user, device}
      {:ok, :expired} -> {:error, :expired}
      {:ok, :unknown_token} -> {:error, :unknown_token}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Creates a new session for the given user. Returns a map with an 
  access/refresh token pair and the access token's expiration. The given device
  ID will overwrite an existing Device with the same ID in the DB, if any. 
  Otherwise, it simply refreshes the tokens on the existing device.
  """
  @spec login(User.id(), String.t(), String.t()) :: {:ok, auth_info()} | {:error, any()}
  def login(user_id, device_id, display_name) do
    case Device.refresh_by(:id, device_id, user_id, {:create, display_name: display_name}) do
      {:ok, device} ->
        {:ok,
         %{
           access_token: device.access_token,
           refresh_token: device.refresh_token,
           expires_in_ms: DateTime.diff(device.expires_at, DateTime.utc_now(), :millisecond)
         }}

      {:error, error} ->
        Logger.error("Error creating user device during login: #{inspect(error)}")

        {:error, error}
    end
  end

  @doc """
  Refreshes a user's session. Returns new access/refresh token information.
  """
  @spec refresh(User.id(), String.t()) :: {:ok, auth_info()} | {:error, any()}
  def refresh(user_id, refresh_token) do
    case Device.refresh_by(:refresh_token, refresh_token, user_id, :error) do
      {:ok, device} ->
        {:ok,
         %{
           access_token: device.access_token,
           refresh_token: device.refresh_token,
           expires_in_ms: DateTime.diff(device.expires_at, DateTime.utc_now(), :millisecond)
         }}

      {:error, error} ->
        Logger.error("User tried to refresh their device with an unknown refresh token: #{inspect(error)}")

        {:error, error}
    end
  end
end
