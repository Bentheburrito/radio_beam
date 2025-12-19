defmodule RadioBeam.User.Device do
  @moduledoc """
  A user's device.
  """

  defstruct [
    :id,
    :display_name,
    :messages,
    :identity_keys,
    :one_time_key_ring,
    :last_issued_token_ids,
    :retryable_refresh_token_id,
    :revoked_unexpired_token_ids,
    :last_seen_at,
    :last_seen_from_ip
  ]

  alias RadioBeam.User
  alias RadioBeam.User.Device.OneTimeKeyRing

  @type t() :: %__MODULE__{}
  @type id() :: term()

  @spec new(String.t(), Keyword.t()) :: t()
  def new(device_id, opts) do
    %__MODULE__{
      id: device_id,
      display_name: Keyword.get(opts, :display_name, default_device_name()),
      messages: %{},
      identity_keys: nil,
      one_time_key_ring: OneTimeKeyRing.new(),
      last_issued_token_ids: %{access: nil, refresh: nil},
      retryable_refresh_token_id: nil,
      revoked_unexpired_token_ids: MapSet.new(),
      last_seen_at: Keyword.get(opts, :last_seen_at, System.os_time(:millisecond)),
      last_seen_from_ip: nil
    }
  end

  def put_last_seen_at(%__MODULE__{} = device, device_ip_tuple, last_seen_at \\ System.os_time(:millisecond)),
    do: struct!(device, last_seen_from_ip: device_ip_tuple, last_seen_at: last_seen_at)

  def put_display_name!(%__MODULE__{} = device, "" <> _ = display_name), do: put_in(device.display_name, display_name)

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

  def put_retryable_refresh_token_id(%__MODULE__{} = device, refresh_token_id_or_nil) do
    put_in(device.retryable_refresh_token_id, refresh_token_id_or_nil)
  end

  def rotate_token_ids(%__MODULE__{} = device, new_access_id, new_refresh_id) do
    revoked_unexpired_token_ids =
      Enum.reduce(device.last_issued_token_ids, device.revoked_unexpired_token_ids, fn
        {_, nil}, revoked_ids -> revoked_ids
        {_, token_id}, revoked_ids -> MapSet.put(revoked_ids, token_id)
      end)

    struct!(device,
      revoked_unexpired_token_ids: revoked_unexpired_token_ids,
      retryable_refresh_token_id: device.last_issued_token_ids.refresh,
      last_issued_token_ids: %{access: new_access_id, refresh: new_refresh_id}
    )
  end

  def default_device_name, do: "New Device (added #{Date.to_string(Date.utc_today())})"
end
