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
    :one_time_key_ring,
    :last_seen_at,
    :last_seen_from_ip
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

  @spec new(Keyword.t()) :: t()
  def new(opts) do
    id = Keyword.get_lazy(opts, :id, &generate_id/0)
    refreshable? = Keyword.get(opts, :refreshable?, true)

    expires_in_ms =
      Keyword.get_lazy(opts, :expires_in_ms, fn ->
        Application.fetch_env!(:radio_beam, :access_token_lifetime)
      end)

    %__MODULE__{
      id: id,
      display_name: Keyword.get(opts, :display_name, default_device_name()),
      access_token: generate_token(),
      refresh_token: if(refreshable?, do: generate_token(), else: nil),
      prev_refresh_token: nil,
      expires_at: DateTime.add(DateTime.utc_now(), expires_in_ms, :millisecond),
      messages: %{},
      identity_keys: nil,
      one_time_key_ring: OneTimeKeyRing.new(),
      last_seen_at: Keyword.get(opts, :last_seen_at, System.os_time(:millisecond)),
      last_seen_from_ip: nil
    }
  end

  def put_last_seen_at(%__MODULE__{} = device, device_ip_tuple, last_seen_at \\ System.os_time(:millisecond)),
    do: struct!(device, last_seen_from_ip: device_ip_tuple, last_seen_at: last_seen_at)

  def put_display_name!(%__MODULE__{} = device, "" <> _ = display_name), do: put_in(device.display_name, display_name)

  @doc "Expires the given device's tokens, setting `expires_at` to `DateTime.utc_now()`"
  @spec expire(t()) :: t()
  def expire(%__MODULE__{} = device), do: put_in(device.expires_at, DateTime.utc_now())

  @doc """
  Generates a new access/refresh token pair for the given user's existing 
  device, moving the current refresh token (if any) to `prev_refresh_token`. 
  """
  @spec refresh(t()) :: t()
  def refresh(%__MODULE__{} = device) do
    %__MODULE__{
      device
      | access_token: generate_token(),
        refresh_token: generate_token(),
        prev_refresh_token: device.refresh_token
    }
  end

  @doc "Puts cross-signing keys for a device"
  @spec put_keys(t(), User.id(), Keyword.t()) :: {:ok, t()} | {:error, :invalid_identity_keys}
  def put_keys(%__MODULE__{} = device, user_id, opts) do
    identity_keys = Keyword.get(opts, :identity_keys, device.identity_keys)

    if valid_identity_keys?(identity_keys, user_id, device.id) do
      one_time_keys = Keyword.get(opts, :one_time_keys, %{})
      fallback_keys = Keyword.get(opts, :fallback_keys, %{})

      otk_ring =
        device.one_time_key_ring
        |> OneTimeKeyRing.put_otks(one_time_keys)
        |> OneTimeKeyRing.put_fallback_keys(fallback_keys)

      {:ok, %__MODULE__{device | one_time_key_ring: otk_ring, identity_keys: identity_keys}}
    else
      {:error, :invalid_identity_keys}
    end
  end

  @spec put_identity_keys_signature(t(), User.id(), map(), Polyjuice.Util.VerifyKey.t()) ::
          {:ok, t()} | {:error, :different_keys | :invalid_signature}
  def put_identity_keys_signature(%__MODULE__{} = device, user_id, key_params_with_new_signature, verify_key) do
    cond do
      # this equality check seems to just be for a better error message, since
      # if we just check the signature against `device.identity_keys`, it would
      # also fail
      Map.delete(device.identity_keys, "signatures") != Map.delete(key_params_with_new_signature, "signatures") ->
        {:error, :different_keys}

      Polyjuice.Util.JSON.signed?(key_params_with_new_signature, user_id, verify_key) ->
        identity_keys =
          RadioBeam.put_nested(
            device.identity_keys,
            ["signatures", user_id, device.id],
            key_params_with_new_signature["signatures"][user_id][device.id]
          )

        {:ok, put_in(device.identity_keys, identity_keys)}

      :else ->
        {:error, :invalid_signature}
    end
  end

  defp valid_identity_keys?(identity_keys, user_id, device_id) do
    is_nil(identity_keys) or
      (Map.get(identity_keys, "device_id", device_id) == device_id and
         Map.get(identity_keys, "user_id", user_id) == user_id)
  end

  def claim_otk(%__MODULE__{} = device, algorithm) do
    with {:ok, {key_id, key, otk_ring}} <- OneTimeKeyRing.claim_otk(device.one_time_key_ring, algorithm) do
      device = put_in(device.one_time_key_ring, otk_ring)
      {:ok, {device, %{"#{algorithm}:#{key_id}" => key}}}
    end
  end

  def generate_id, do: Ecto.UUID.generate()
  def generate_token(), do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64()
  def default_device_name, do: "New Device (added #{Date.to_string(Date.utc_today())})"
end
