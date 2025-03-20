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
    device_map: :map
  ]
  @attrs Keyword.keys(@types)

  @type id() :: String.t()

  use Memento.Table,
    attributes: @attrs,
    type: :set

  import Ecto.Changeset

  alias RadioBeam.Credentials
  alias RadioBeam.Repo
  alias RadioBeam.User.CrossSigningKeyRing
  alias RadioBeam.User.Device

  require Logger

  @type t() :: %__MODULE__{}

  def new(id, password) do
    params = %{
      id: id,
      pwd_hash: Credentials.hash_pwd(password),
      registered_at: DateTime.utc_now(),
      account_data: %{},
      cross_signing_key_ring: CrossSigningKeyRing.new(),
      device_map: %{}
    }

    {%__MODULE__{}, Map.new(@types)}
    |> cast(params, @attrs)
    |> validate_required([:id])
    |> validate_length(:id, max: 255)
    |> validate_user_id()
    |> validate_password(password)
    |> apply_action(:update)
  end

  @doc "Gets a local user by their user ID"
  @spec get(id()) :: {:ok, t()} | {:error, :not_found}
  def get(id, opts \\ []) do
    Repo.one_shot(fn ->
      case Memento.Query.read(__MODULE__, id, opts) do
        nil -> {:error, :not_found}
        user -> {:ok, user}
      end
    end)
  end

  @doc "Gets all users of the given IDs"
  @spec all([id()]) :: [t()]
  def all(ids, opts \\ []) do
    Repo.one_shot(fn ->
      Enum.reduce(ids, [], fn id, acc ->
        case get(id, opts) do
          {:error, :not_found} -> acc
          {:ok, user} -> [user | acc]
        end
      end)
    end)
  end

  @doc """
  Persists a User to the DB, unless a record with the same ID already exists.
  """
  @spec put_new(t()) :: {:ok, t()} | {:error, :already_exists | any()}
  def put_new(%__MODULE__{} = user) do
    Repo.one_shot(fn ->
      case get(user.id, lock: :write) do
        {:ok, %__MODULE__{}} -> {:error, :already_exists}
        {:error, :not_found} -> {:ok, Memento.Query.write(user)}
      end
    end)
  end

  @doc """
  Writes global or room account data for a user. Any existing content for a
  scope + key is overwritten (not merged). Returns `:ok`
  if the account data was successfully written, and an error tuple otherwise.
  """
  def put_account_data(user_id, scope \\ :global, type, content)

  @invalid_types ~w|m.fully_read m.push_rules|
  def put_account_data(_user_id, _scope, type, _content) when type in @invalid_types, do: {:error, :invalid_type}

  def put_account_data(user_id, scope, type, content) do
    parse_scope = fn
      :global ->
        {:ok, :global}

      "!" <> _rest = room_id ->
        # TODO - weird to cross boundary from User -> Room here, alternative?
        case RadioBeam.Room.get(room_id) do
          {:ok, %RadioBeam.Room{}} -> {:ok, room_id}
          {:error, _} -> {:error, :invalid_room_id}
        end
    end

    Repo.one_shot(fn ->
      with {:ok, %__MODULE__{} = user} <- get(user_id, lock: :write),
           {:ok, scope} <- parse_scope.(scope) do
        account_data = RadioBeam.put_nested(user.account_data, [scope, type], content)
        user = %__MODULE__{user | account_data: account_data}
        Memento.Query.write(user)
        :ok
      end
    end)
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
      if Credentials.strong_password?(password) do
        []
      else
        [pwd_hash: "password is too weak"]
      end
    end)
  end

  ### DEVICE ###

  @doc "Puts a device for the given User, overriding any existing entry."
  @spec put_device(t(), Device.t()) :: t()
  def put_device(%__MODULE__{} = user, %Device{} = device), do: put_in(user.device_map[device.id], device)

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
end
