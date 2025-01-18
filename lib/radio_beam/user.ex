defmodule RadioBeam.User do
  @moduledoc """
  A user registered on this homeserver.
  """
  @types [
    id: :string,
    account_data: :map,
    pwd_hash: :string,
    registered_at: :utc_datetime,
    cross_signing_key_ring: :map
  ]
  @attrs Keyword.keys(@types)

  @type id :: String.t()

  use Memento.Table,
    attributes: @attrs,
    type: :set

  import Ecto.Changeset

  alias RadioBeam.User.CrossSigningKey
  alias RadioBeam.Device
  alias RadioBeam.Credentials
  alias RadioBeam.Repo
  alias RadioBeam.User.CrossSigningKeyRing

  require Logger

  @type t() :: %__MODULE__{}

  def new(id, password) do
    params = %{
      id: id,
      pwd_hash: Credentials.hash_pwd(password),
      registered_at: DateTime.utc_now(),
      account_data: %{},
      cross_signing_key_ring: CrossSigningKeyRing.new()
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

  @doc """
  Queries all local users' keys by the given map of %{user_id => [device_id]}.
  Only signatures the given `user_id` is allowed to view will be included.
  """
  @spec query_all_keys(%{User.id() => [Device.id()]}, User.id()) :: map()
  def query_all_keys(query_map, querying_user_id) do
    Repo.one_shot(fn ->
      with {:ok, querying_user} <- get(querying_user_id) do
        Enum.reduce(query_map, %{}, fn
          {^querying_user_id, device_ids}, key_results ->
            add_authz_keys(key_results, querying_user, querying_user, device_ids)

          {user_id, device_ids}, key_results ->
            case Memento.Query.read(__MODULE__, user_id) do
              nil -> key_results
              user -> add_authz_keys(key_results, user, device_ids)
            end
        end)
      end
    end)
  end

  defp add_authz_keys(key_results, %{id: id} = user, %{id: id}, device_ids) do
    key_results
    |> add_authz_keys(user, device_ids)
    |> put_csk(["user_signing_keys", user.id], user.cross_signing_key_ring.user, user.id)
  end

  defp add_authz_keys(key_results, user, device_ids) do
    key_results
    # TODO: strip signatures the user is not allowed to see
    |> put_csk(["master_keys", user.id], user.cross_signing_key_ring.master, user.id)
    |> put_csk(["self_signing_keys", user.id], user.cross_signing_key_ring.self, user.id)
    |> put_device_keys(user.id, device_ids)
  end

  defp put_csk(key_results, _path, nil, _user_id), do: key_results

  defp put_csk(key_results, path, %CrossSigningKey{} = key, user_id) do
    RadioBeam.put_nested(key_results, path, CrossSigningKey.to_map(key, user_id))
  end

  defp put_device_keys(key_results, user_id, device_ids) do
    case Device.get_all_by_user(user_id) do
      {:ok, devices} ->
        for %{id: device_id} = device <- devices,
            Enum.empty?(device_ids) or device_id in device_ids,
            reduce: key_results do
          key_results -> RadioBeam.put_nested(key_results, ["device_keys", user_id, device_id], device.identity_keys)
        end

      {:error, error} ->
        Logger.error("Failed to get devices by user ID #{inspect(user_id)} while querying devices: #{inspect(error)}")
        key_results
    end
  end

  @doc """
  Persists a User to the DB, unless a record with the same ID already exists.
  """
  @spec put_new(t()) :: :ok | {:error, :already_exists | any()}
  def put_new(%__MODULE__{} = user) do
    Repo.one_shot(fn ->
      case get(user.id, lock: :write) do
        {:ok, %__MODULE__{}} ->
          {:error, :already_exists}

        {:error, :not_found} ->
          Memento.Query.write(user)
          :ok
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
end
