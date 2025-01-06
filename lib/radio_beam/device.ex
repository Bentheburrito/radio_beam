defmodule RadioBeam.Device do
  @moduledoc """
  A user's device. A device has an entry in this table for every pair of 
  access/refresh tokens.
  """

  defstruct [
    :id,
    :user_id,
    :display_name,
    :access_token,
    :refresh_token,
    :prev_refresh_token,
    :expires_at,
    :messages,
    :identity_keys,
    :one_time_key_ring
  ]

  alias RadioBeam.Device.OneTimeKeyRing
  alias RadioBeam.Device.Table
  alias RadioBeam.Repo
  alias RadioBeam.User

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

  @spec new(User.id(), Keyword.t()) :: t()
  def new(user_id, opts) do
    id = Keyword.get_lazy(opts, :id, &generate_token/0)
    refreshable? = Keyword.get(opts, :refreshable?, true)

    expires_in_ms =
      Keyword.get_lazy(opts, :expires_in_ms, fn ->
        Application.fetch_env!(:radio_beam, :access_token_lifetime)
      end)

    %__MODULE__{
      id: id,
      user_id: user_id,
      display_name: Keyword.get(opts, :display_name, default_device_name()),
      access_token: generate_token(),
      refresh_token: if(refreshable?, do: generate_token(), else: nil),
      prev_refresh_token: nil,
      expires_at: DateTime.add(DateTime.utc_now(), expires_in_ms, :millisecond),
      messages: %{},
      identity_keys: nil,
      one_time_key_ring: OneTimeKeyRing.new()
    }
  end

  defdelegate get(user_id, device_id, opts \\ []), to: Table
  defdelegate get_all_by_user(user_id), to: Table
  defdelegate get_by_access_token(access), to: Table
  defdelegate get_by_refresh_token(refresh, lock \\ :read), to: Table

  @doc """
  Upkeep that needs to happen when an access token or refresh token is used.
  Namely, marking the previous refresh token (if any) as `nil`.

  > The old refresh token remains valid until the new access token or refresh 
  > token is used, at which point the old refresh token is revoked. This 
  > ensures that if a client fails to receive or persist the new tokens, it 
  > will be able to repeat the refresh operation.
  """
  def upkeep(%__MODULE__{prev_refresh_token: nil} = device), do: device

  def upkeep(%__MODULE__{} = device) do
    Table.persist(%__MODULE__{device | prev_refresh_token: nil})
  end

  @doc "Expires the given device's tokens, setting `expires_at` to `DateTime.utc_now()`"
  def expire(%__MODULE__{} = device),
    do: Repo.one_shot(fn -> Table.persist(%__MODULE__{device | expires_at: DateTime.utc_now()}) end)

  @doc """
  Generates a new access/refresh token pair for the given user ID's existing 
  device, moving the current refresh token to to `prev_refresh_token`. 

  The last argument describes what will happen if a device could not be found
  using the given `field` and `value`. Valid options are:
  - `:error`: simply returns `{:error, :not_found}`.
  - `{:create, opts}` creates and persists a new device using `opts`. `field`
  will be put in the `opts` and set to `value`.
  """
  def refresh_by(field, value, user_id, on_not_found \\ :error) do
    on_not_found = fn ->
      case on_not_found do
        :error ->
          {:error, :not_found}

        {:create, opts} ->
          device = new(user_id, Keyword.put(opts, field, value))
          Table.persist(device)
      end
    end

    Repo.one_shot(fn ->
      case get_device_by(field, value, user_id) do
        {:ok, device} -> try_refresh(device, user_id, on_not_found)
        {:error, :not_found} -> on_not_found.()
      end
    end)
  end

  @doc "Put cross-signing keys for a device"
  @spec put_keys(User.id(), String.t(), Keyword.t()) ::
          {:ok, t()} | {:error, :not_found | :user_does_not_exist | :invalid_user_or_device_id}
  def put_keys(user_id, device_id, opts) do
    one_time_keys = Keyword.get(opts, :one_time_keys, %{})
    fallback_keys = Keyword.get(opts, :fallback_keys, %{})

    Repo.one_shot(fn ->
      with {:ok, %__MODULE__{} = device} = Table.get(user_id, device_id, lock: :write) do
        otk_ring =
          device.one_time_key_ring
          |> OneTimeKeyRing.put_otks(one_time_keys)
          |> OneTimeKeyRing.put_fallback_keys(fallback_keys)

        identity_keys = Keyword.get(opts, :identity_keys, device.identity_keys)

        if valid_identity_keys?(identity_keys, user_id, device_id) do
          Table.persist(%__MODULE__{device | one_time_key_ring: otk_ring, identity_keys: identity_keys})
        else
          {:error, :invalid_user_or_device_id}
        end
      end
    end)
  end

  defp valid_identity_keys?(identity_keys, user_id, device_id) do
    is_nil(identity_keys) or
      (Map.get(identity_keys, "device_id", device_id) == device_id and
         Map.get(identity_keys, "user_id", user_id) == user_id)
  end

  def claim_otks(user_device_algo_map) do
    Repo.one_shot(fn ->
      Map.new(user_device_algo_map, fn {user_id, device_algo_map} ->
        device_key_map =
          device_algo_map
          |> Stream.map(fn {device_id, algo} ->
            with {:ok, %__MODULE__{} = device} <- Table.get(user_id, device_id, lock: :write),
                 {:ok, {key, otk_ring}} <- OneTimeKeyRing.claim_otk(device.one_time_key_ring, algo),
                 {:ok, _device} <- Table.persist(%__MODULE__{device | one_time_key_ring: otk_ring}) do
              {key_id, key} = Map.pop!(key, "id")
              {device_id, %{"#{algo}:#{key_id}" => key}}
            else
              _error -> :ignore
            end
          end)
          |> Stream.reject(&(&1 == :ignore))
          |> Map.new()

        {user_id, device_key_map}
      end)
    end)
  end

  defp get_device_by(field, value, user_id) do
    case field do
      :id -> Table.get(user_id, value, lock: :write)
      :refresh_token -> Table.get_by_refresh_token(value, :write)
    end
  end

  defp try_refresh(device, user_id, on_not_found) do
    case device do
      %__MODULE__{user_id: ^user_id, prev_refresh_token: nil} = device ->
        Table.persist(%__MODULE__{
          device
          | access_token: generate_token(),
            refresh_token: generate_token(),
            prev_refresh_token: device.refresh_token
        })

      # if prev_refresh_token is not nil, do nothing; the client probably 
      # didn't receive the response for the initial refresh call
      %__MODULE__{user_id: ^user_id} = device ->
        {:ok, device}

      _not_found ->
        on_not_found.()
    end
  end

  def generate_token, do: Ecto.UUID.generate()
  def default_device_name, do: "New Device (added #{Date.to_string(Date.utc_today())})"
end
