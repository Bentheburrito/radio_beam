defmodule RadioBeam.Device do
  @moduledoc """
  A user's device. A device has an entry in this table for every pair of 
  access/refresh tokens.
  """

  @attrs [
    :id,
    :user_id,
    :display_name,
    :access_token,
    :refresh_token,
    :prev_refresh_token,
    :expires_at,
    :messages
  ]
  use Memento.Table,
    attributes: @attrs,
    index: [:user_id, :access_token, :refresh_token, :prev_refresh_token],
    type: :set

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

  @doc "Gets a %Device{}"
  def get(user_id, device_id) do
    case Memento.transaction(fn -> getT(user_id, device_id) end) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, device} -> {:ok, device}
      error -> error
    end
  end

  @doc """
  Similar to `get/2`, but must be called inside a transaction.
  """
  def getT(user_id, device_id, opts \\ []) do
    format(Memento.Query.read(__MODULE__, {user_id, device_id}, opts))
  end

  def get_all_by_user(user_id) do
    match_head = __MODULE__.__info__().query_base
    match_spec = [{put_elem(match_head, 1, {user_id, :_}), [], [:"$_"]}]

    case Memento.transaction(fn -> Memento.Query.select_raw(__MODULE__, match_spec) end) do
      {:ok, records} when is_list(records) -> {:ok, Enum.map(records, &format/1)}
      {:ok, :"$end_of_table"} -> {:ok, []}
      {:error, error} -> {:error, error}
    end
  end

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
    persist(%__MODULE__{device | prev_refresh_token: nil})
  end

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
    fn ->
      device =
        case field do
          :id -> format(Memento.Query.read(__MODULE__, {user_id, value}, lock: :write))
          :refresh_token -> select_by_refresh_token(value, :write)
        end

      try_refresh(device, user_id, field, value, on_not_found)
    end
    |> Memento.transaction()
    |> case do
      {:ok, %__MODULE__{} = device} -> {:ok, format(device)}
      {:ok, :not_found} -> {:error, :not_found}
      {:ok, :user_does_not_exist} -> {:error, :user_does_not_exist}
      error -> error
    end
  end

  defp try_refresh(device, user_id, field, value, on_not_found) do
    case device do
      %__MODULE__{user_id: ^user_id, prev_refresh_token: nil} = device ->
        persist(%__MODULE__{
          device
          | access_token: generate_token(),
            refresh_token: generate_token(),
            prev_refresh_token: device.refresh_token
        })

      # if prev_refresh_token is not nil, do nothing; the client probably 
      # didn't receive the response for the initial refresh call
      %__MODULE__{user_id: ^user_id} = device ->
        device

      _not_found ->
        case on_not_found do
          :error ->
            :not_found

          {:create, opts} ->
            device = new(user_id, Keyword.put(opts, field, value))
            persist(device)
        end
    end
  end

  @spec select_by_access_token(access_token :: binary()) :: t() | :none
  def select_by_access_token(access_token) do
    case Memento.Query.select(__MODULE__, {:==, :access_token, access_token}, limit: 1) do
      [device] -> format(device)
      _ -> :none
    end
  end

  def select_by_refresh_token(refresh_token, lock \\ :read) do
    guard = {:or, {:==, :refresh_token, refresh_token}, {:==, :prev_refresh_token, refresh_token}}

    case Memento.Query.select(__MODULE__, guard, limit: 1, lock: lock) do
      [device] -> format(device)
      _ -> :none
    end
  end

  def generate_token, do: Ecto.UUID.generate()
  def default_device_name, do: "New Device (added #{Date.to_string(Date.utc_today())})"

  def persist(device) do
    if is_nil(Memento.Query.read(User, device.user_id)) do
      :user_does_not_exist
    else
      format(Memento.Query.write(%__MODULE__{device | id: {device.user_id, device.id}}))
    end
  end

  # this is a bit awkward: we want device IDs to be unique for each user, so
  # we tag the ID with the user ID as it is persisted in the data layer 
  # (above). This means modules here must undo that when a Device is read from
  # the DB...very brittle and should be addressed at some point (e.g. maybe
  # I just bite the bullet and update all callers to match out the device ID
  # from the tuple before sending user's the response)
  defp format(%__MODULE__{id: {user_id, id}, user_id: user_id} = device) do
    %__MODULE__{device | id: id}
  end

  defp format(device), do: device
end
