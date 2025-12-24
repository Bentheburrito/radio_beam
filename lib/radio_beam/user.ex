defmodule RadioBeam.User do
  @moduledoc """
  A user registered on this homeserver.
  """
  @types [
    id: :string,
    account_data: :map,
    pwd_hash: :string,
    registered_at: :utc_datetime,
    cross_signing_key_ring: :map,
    last_cross_signing_change_at: :integer,
    room_keys: :map,
    device_map: :map,
    filter_map: :map
  ]
  @attrs Keyword.keys(@types)

  @type id() :: String.t()

  defstruct @attrs

  import Ecto.Changeset

  alias RadioBeam.User.RoomKeys
  alias RadioBeam.User.CrossSigningKeyRing
  alias RadioBeam.User.Device
  alias RadioBeam.User.EventFilter

  @type t() :: %__MODULE__{}

  @hash_pwd_opts [t_cost: 3, m_cost: 12, parallelism: 1]
  def hash_pwd_opts, do: @hash_pwd_opts

  def dump!(user), do: user
  def load!(user), do: user

  def new(id, password) do
    params = %{
      id: id,
      pwd_hash: Argon2.hash_pwd_salt(password, @hash_pwd_opts),
      registered_at: DateTime.utc_now(),
      account_data: %{},
      cross_signing_key_ring: CrossSigningKeyRing.new(),
      last_cross_signing_change_at: 0,
      room_keys: RoomKeys.new!(),
      device_map: %{},
      filter_map: %{}
    }

    {%__MODULE__{}, Map.new(@types)}
    |> cast(params, @attrs)
    |> validate_required([:id])
    |> validate_length(:id, max: 255)
    |> validate_user_id()
    |> validate_password(password)
    |> apply_action(:update)
  end

  def validate_user_id(id) when is_binary(id) do
    case String.split(id, ":") do
      ["@" <> localpart, _server_name] when localpart != "" -> validate_localpart(localpart)
      _invalid_format -> [id: "User IDs must be of the form @localpart:servername"]
    end
  end

  def validate_user_id(changeset) do
    validate_change(changeset, :id, fn :id, id -> validate_user_id(id) end)
  end

  defp validate_localpart(localpart) do
    if Regex.match?(~r|^[a-z0-9\._=/+-]+$|, localpart) do
      []
    else
      [id: "localpart can only contain lowercase alphanumeric characters, or the symbols ._=-/+"]
    end
  end

  defp validate_password(changeset, password) do
    validate_change(changeset, :pwd_hash, fn :pwd_hash, _pwd_hash ->
      if strong_password?(password) do
        []
      else
        [pwd_hash: "password is too weak"]
      end
    end)
  end

  @doc "Checks if the password is strong"
  @spec strong_password?(String.t()) :: boolean()
  def strong_password?(password) do
    Regex.match?(~r/^(?=.*[A-Z])(?=.*[!@#$%^&*\(\)\-+=\{\[\}\]|\\:;"'<,>.?\/])(?=.*[0-9])(?=.*[a-z]).{8,}$/, password)
  end

  @doc """
  Puts global or room account data for a user. Any existing content for a
  scope + key is overwritten (not merged). Returns `:ok`
  if the account data was successfully written, and an error tuple otherwise.
  """
  def put_account_data(user, scope \\ :global, type, content)

  @invalid_types ~w|m.fully_read m.push_rules|
  def put_account_data(_user, _scope, type, _content) when type in @invalid_types, do: {:error, :invalid_type}

  def put_account_data(%__MODULE__{} = user, scope, type, content) do
    account_data = RadioBeam.put_nested(user.account_data, [scope, type], content)
    {:ok, %__MODULE__{user | account_data: account_data}}
  end

  ### DEVICE ###

  @doc "Puts a device for the given User, overriding any existing entry."
  @spec put_device(t(), Device.t()) :: t()
  def put_device(%__MODULE__{} = user, %Device{identity_keys: identity_keys} = device) do
    if match?(%{identity_keys: ^identity_keys}, user.device_map[device.id]) do
      put_in(user.device_map[device.id], device)
    else
      struct!(user,
        device_map: Map.put(user.device_map, device.id, device),
        last_cross_signing_change_at: System.os_time(:millisecond)
      )
    end
  end

  @doc "Deletes a User's device by ID. No-op if the device doesn't exist."
  @spec delete_device(t(), Device.id()) :: t()
  def delete_device(%__MODULE__{} = user, device_id) when is_map_key(user.device_map, device_id) do
    struct!(user,
      device_map: Map.delete(user.device_map, device_id),
      last_cross_signing_change_at: System.os_time(:millisecond)
    )
  end

  def delete_device(%__MODULE__{} = user, _device_id), do: user

  @doc "Gets a User's device"
  @spec get_device(t(), Device.id()) :: {:ok, Device.t()} | {:error, :not_found}
  def get_device(%__MODULE__{} = user, device_id) do
    with :error <- Map.fetch(user.device_map, device_id), do: {:error, :not_found}
  end

  @doc "Gets all of a User's devices"
  @spec get_all_devices(t()) :: [Device.t()]
  def get_all_devices(%__MODULE__{} = user), do: Map.values(user.device_map)

  @doc """
  Claims one-time keys from a set of user's devices. This function expects a
  map like `%{%User{} => %{device_id => algorithm_name}}`.
  """
  @spec claim_device_otks(%{required(t()) => %{required(Device.id()) => algorithm :: String.t()}}) :: map()
  def claim_device_otks(user_device_algo_map) do
    Map.new(user_device_algo_map, fn {%__MODULE__{} = user, device_algo_map} ->
      Enum.reduce(device_algo_map, {user, %{}}, fn {device_id, algo}, {%__MODULE__{} = user, device_key_map} ->
        with {:ok, %Device{} = device} <- get_device(user, device_id),
             {:ok, {%Device{} = device, one_time_key}} <- Device.claim_otk(device, algo) do
          {put_device(user, device), Map.put(device_key_map, device.id, one_time_key)}
        else
          _error -> {user, device_key_map}
        end
      end)
    end)
  end

  def put_room_keys(%__MODULE__{} = user, %RoomKeys{} = room_keys), do: put_in(user.room_keys, room_keys)

  ### FILTER ###

  @doc "Saves an event filter for the given User, overriding any existing entry."
  @spec put_event_filter(t(), EventFilter.t()) :: t()
  def put_event_filter(%__MODULE__{} = user, %EventFilter{} = filter) do
    put_in(user.filter_map[filter.id], filter)
  end

  @doc "Gets an event filter previously uploaded by the given User"
  @spec get_event_filter(t(), EventFilter.id()) :: {:ok, EventFilter.t()} | {:error, :not_found}
  def get_event_filter(%__MODULE__{} = user, filter_id) do
    with :error <- Map.fetch(user.filter_map, filter_id), do: {:error, :not_found}
  end
end
