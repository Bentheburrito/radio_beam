defmodule RadioBeam.User.Device do
  @moduledoc """
  A user's device. A device has an entry in this table for every pair of 
  access/refresh tokens.
  """

  defstruct [
    :id,
    :display_name,
    :access_token,
    :refresh_token,
    :prev_refresh_token,
    :expires_at,
    :messages,
    :identity_keys,
    :one_time_key_ring
  ]

  alias RadioBeam.User
  alias RadioBeam.User.Device.OneTimeKeyRing

  @typedoc """
  A user's device.

  `prev_refresh_token` will be `nil` most of the time. It will only have
  the previos refresh token for a limited window of time: from the time a 
  client refreshes its device's tokens, to the new token's first use.

  "The old refresh token remains valid until the new access token or refresh 
  token is used, at which point the old refresh token is revoked. This ensures 
  that if a client fails to receive or persist the new tokens, it will be able 
  to repeat the refresh operation."
  """
  @type t() :: %__MODULE__{}
  @type id() :: term()

  @typedoc """
  A string representing an access or refresh token. The token is divided into
  three parts: user ID, device ID, token, all delimited by a colon (`:`). For
  example: `"@someone:somewhere:abcdEFG:XYZxyz"`
  """
  @opaque auth_token() :: String.t()

  @spec new(User.t(), Keyword.t()) :: User.t()
  def new(%User{} = user, opts) do
    id = Keyword.get_lazy(opts, :id, &generate_id/0)
    refreshable? = Keyword.get(opts, :refreshable?, true)

    expires_in_ms =
      Keyword.get_lazy(opts, :expires_in_ms, fn ->
        Application.fetch_env!(:radio_beam, :access_token_lifetime)
      end)

    put_in(
      user.device_map[id],
      %__MODULE__{
        id: id,
        display_name: Keyword.get(opts, :display_name, default_device_name()),
        access_token: generate_token(user.id, id),
        refresh_token: if(refreshable?, do: generate_token(user.id, id), else: nil),
        prev_refresh_token: nil,
        expires_at: DateTime.add(DateTime.utc_now(), expires_in_ms, :millisecond),
        messages: %{},
        identity_keys: nil,
        one_time_key_ring: OneTimeKeyRing.new()
      }
    )
  end

  @spec get(User.t(), id()) :: {:ok, t()} | {:error, :not_found}
  def get(%User{} = user, device_id) do
    with :error <- Map.fetch(user.device_map, device_id), do: {:error, :not_found}
  end

  @spec get_all(User.t()) :: [t()]
  def get_all(%User{} = user), do: Map.values(user.device_map)

  @doc "Expires the given device's tokens, setting `expires_at` to `DateTime.utc_now()`"
  @spec expire(User.t(), id()) :: {:ok, User.t()} | {:error, :not_found}
  def expire(%User{} = user, device_id) do
    with {:ok, %__MODULE__{} = _device} <- get(user, device_id) do
      {:ok, put_in(user.device_map[device_id].expires_at, DateTime.utc_now())}
    end
  end

  @doc """
  Generates a new access/refresh token pair for the given user's existing 
  device, moving the current refresh token to `prev_refresh_token`. 
  """
  @spec refresh(User.t(), id) :: {:ok, User.t()} | {:error, :not_found}
  def refresh(%User{} = user, device_id) do
    with {:ok, %__MODULE__{} = device} <- get(user, device_id) do
      prev_refresh_token =
        if is_nil(device.prev_refresh_token), do: device.refresh_token, else: device.prev_refresh_token

      {:ok,
       put_in(user.device_map[device.id], %__MODULE__{
         device
         | access_token: generate_token(user.id, device_id),
           refresh_token: generate_token(user.id, device_id),
           prev_refresh_token: prev_refresh_token
       })}
    end
  end

  @doc "Put cross-signing keys for a device"
  @spec put_keys(User.t(), id(), Keyword.t()) ::
          {:ok, User.t()} | {:error, :not_found | :user_does_not_exist | :invalid_user_or_device_id}
  def put_keys(%User{} = user, device_id, opts) do
    one_time_keys = Keyword.get(opts, :one_time_keys, %{})
    fallback_keys = Keyword.get(opts, :fallback_keys, %{})

    with {:ok, %__MODULE__{} = device} = get(user, device_id) do
      otk_ring =
        device.one_time_key_ring
        |> OneTimeKeyRing.put_otks(one_time_keys)
        |> OneTimeKeyRing.put_fallback_keys(fallback_keys)

      identity_keys = Keyword.get(opts, :identity_keys, device.identity_keys)

      if valid_identity_keys?(identity_keys, user.id, device_id) do
        {:ok,
         put_in(user.device_map[device_id], %__MODULE__{
           device
           | one_time_key_ring: otk_ring,
             identity_keys: identity_keys
         })}
      else
        {:error, :invalid_user_or_device_id}
      end
    end
  end

  @spec put_identity_keys_signature(User.t(), id(), map(), Polyjuice.Util.VerifyKey.t()) ::
          {:ok, User.t()} | {:error, :different_keys | :invalid_signature}
  def put_identity_keys_signature(%User{} = user, device_id, key_params_with_new_signature, verify_key) do
    with {:ok, %__MODULE__{} = device} <- get(user, device_id) do
      cond do
        # this equality check seems to just be for a better error message, since
        # if we just check the signature against `device.identity_keys`, it would
        # also fail
        Map.delete(device.identity_keys, "signatures") != Map.delete(key_params_with_new_signature, "signatures") ->
          {:error, :different_keys}

        Polyjuice.Util.JSON.signed?(key_params_with_new_signature, user.id, verify_key) ->
          identity_keys =
            RadioBeam.put_nested(
              device.identity_keys,
              ["signatures", user.id, device.id],
              key_params_with_new_signature["signatures"][user.id][device.id]
            )

          {:ok, put_in(user.device_map[device_id].identity_keys, identity_keys)}

        :else ->
          {:error, :invalid_signature}
      end
    end
  end

  defp valid_identity_keys?(identity_keys, user_id, device_id) do
    is_nil(identity_keys) or
      (Map.get(identity_keys, "device_id", device_id) == device_id and
         Map.get(identity_keys, "user_id", user_id) == user_id)
  end

  def claim_otks(user_device_algo_map) do
    Map.new(user_device_algo_map, fn {%User{} = user, device_algo_map} ->
      Enum.reduce(device_algo_map, {user, %{}}, fn {device_id, algo}, {%User{} = user, device_key_map} ->
        with {:ok, %__MODULE__{} = device} <- get(user, device_id),
             {:ok, {key, otk_ring}} <- OneTimeKeyRing.claim_otk(device.one_time_key_ring, algo) do
          user = put_in(user.device_map[device_id].one_time_key_ring, otk_ring)
          {key_id, key} = Map.pop!(key, "id")
          {user, Map.put(device_key_map, device_id, %{"#{algo}:#{key_id}" => key})}
        else
          _error -> {user, device_key_map}
        end
      end)
    end)
  end

  def generate_id, do: Ecto.UUID.generate()
  def generate_token(user_id, device_id), do: "#{user_id}:#{device_id}:#{Ecto.UUID.generate()}"
  def default_device_name, do: "New Device (added #{Date.to_string(Date.utc_today())})"
end
