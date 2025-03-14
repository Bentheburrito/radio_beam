defmodule RadioBeam.User.Auth do
  @moduledoc """
  Functions for authenticating users
  """

  alias RadioBeam.Repo
  alias RadioBeam.User
  alias RadioBeam.User.Device

  require Logger

  @type auth_info() :: %{
          required(:access_token) => Device.auth_token(),
          required(:refresh_token) => Device.auth_token(),
          required(:expires_in_ms) => non_neg_integer()
        }

  @doc """
  Authenticate a user by a token. Returns the authenticated user and device if
  successful, and an error tuple describing the problem with the token
  (invaild, expired) otherwise.
  """
  @spec get_user_and_device_by_token(Device.auth_token()) ::
          {:ok, User.t(), Device.t()} | {:error, :expired | :unknown_token | any()}
  def get_user_and_device_by_token(token) do
    Repo.one_shot(fn ->
      with ["@" <> localpart, servername, device_id, _uniqpart] <- String.split(token, ":"),
           {:ok, %User{} = user} <- User.get("@#{localpart}:#{servername}"),
           {:ok, %Device{} = device} <- Device.get(user, device_id),
           {:ok, %User{} = user} <- check_token_and_upkeep(user, device, token),
           :lt <- DateTime.compare(DateTime.utc_now(), device.expires_at) do
        user = Memento.Query.write(user)
        {:ok, device} = Device.get(user, device.id)
        {:ok, user, device}
      else
        compare_result when compare_result in [:eq, :gt] -> {:error, :expired}
        _ -> {:error, :unknown_token}
      end
    end)
  end

  defp check_token_and_upkeep(user, device, token) do
    access_match? = Plug.Crypto.secure_compare(token, device.access_token)
    refresh_match? = Plug.Crypto.secure_compare(token, device.refresh_token || "")
    prev_refresh_match? = Plug.Crypto.secure_compare(token, device.prev_refresh_token || "")

    cond do
      access_match? or refresh_match? -> {:ok, put_in(user.device_map[device.id].prev_refresh_token, nil)}
      prev_refresh_match? -> {:ok, user}
      :else -> {:error, :not_found}
    end
  end

  @doc """
  Creates or refreshes a session for the given user's device. The device will
  be created if one under the given ID doesn't already exist. Returns a map
  with an access/refresh token pair and the access token's expiration.
  """
  @spec upsert_device_session(User.t(), Device.id(), String.t()) :: auth_info()
  def upsert_device_session(%User{} = user, device_id, display_name) do
    user =
      case Device.refresh(user, device_id) do
        {:error, :not_found} -> Device.new(user, id: device_id, display_name: display_name)
        {:ok, user} -> user
      end

    Repo.one_shot!(fn -> Memento.Query.write(user) end)
    {:ok, device} = Device.get(user, device_id)

    %{
      access_token: device.access_token,
      refresh_token: device.refresh_token,
      expires_in_ms: DateTime.diff(device.expires_at, DateTime.utc_now(), :millisecond)
    }
  end

  @doc """
  Refreshes a user's session. Returns new access/refresh token information.
  """
  @spec refresh(Device.auth_token()) :: {:ok, auth_info()} | {:error, any()}
  def refresh(refresh_token) do
    with {:ok, %User{} = user, device} <- get_user_and_device_by_token(refresh_token),
         {:ok, %User{} = user} <- Device.refresh(user, device.id),
         {:ok, %User{} = user} <- Repo.one_shot(fn -> {:ok, Memento.Query.write(user)} end) do
      {:ok, device} = Device.get(user, device.id)

      {:ok,
       %{
         access_token: device.access_token,
         refresh_token: device.refresh_token,
         expires_in_ms: DateTime.diff(device.expires_at, DateTime.utc_now(), :millisecond)
       }}
    else
      {:error, error} ->
        Logger.error("User tried to refresh their device with an unknown refresh token: #{inspect(error)}")

        {:error, error}
    end
  end
end
