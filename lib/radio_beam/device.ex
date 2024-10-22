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
    :messages
  ]

  alias RadioBeam.Repo
  alias RadioBeam.Device.Table
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
      messages: %{}
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
