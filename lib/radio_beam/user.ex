defmodule RadioBeam.User do
  @moduledoc """
  A user registered on this homeserver.
  """
  @types [id: :string, account_data: :map, pwd_hash: :string, registered_at: :utc_datetime]
  @attrs Keyword.keys(@types)

  @type id :: String.t()

  use Memento.Table,
    attributes: @attrs,
    type: :set

  import Ecto.Changeset

  alias RadioBeam.Credentials

  @type t() :: %__MODULE__{}

  def new(id, password) do
    params = %{
      id: id,
      pwd_hash: Credentials.hash_pwd(password),
      registered_at: DateTime.utc_now(),
      account_data: %{}
    }

    {%__MODULE__{}, Map.new(@types)}
    |> cast(params, @attrs)
    |> validate_required([:id])
    |> validate_length(:id, max: 255)
    |> validate_user_id()
    |> validate_password(password)
    |> apply_action(:update)
  end

  @doc "Gets a user by their user ID"
  @spec get(id()) :: {:ok, t() | nil} | {:error, any()}
  def get(id), do: Memento.transaction(fn -> Memento.Query.read(__MODULE__, id) end)

  @doc """
  Persists a User to the DB, unless a record with the same ID already exists.
  """
  @spec put_new(t()) :: :ok | {:error, :already_exists | any()}
  def put_new(%__MODULE__{} = user) do
    fn ->
      case Memento.Query.read(__MODULE__, user.id) do
        %__MODULE__{} -> :already_exists
        nil -> Memento.Query.write(user)
      end
    end
    |> Memento.transaction()
    |> case do
      {:ok, :already_exists} -> {:error, :already_exists}
      {:ok, %__MODULE__{}} -> :ok
      error -> error
    end
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
        case Memento.Query.read(RadioBeam.Room, room_id) do
          %RadioBeam.Room{} -> {:ok, room_id}
          _else -> {:error, :invalid_room_id}
        end
    end

    fn ->
      with %__MODULE__{} = user <- Memento.Query.read(__MODULE__, user_id),
           {:ok, scope} <- parse_scope.(scope) do
        account_data = RadioBeam.put_nested(user.account_data, [scope, type], content)
        user = %__MODULE__{user | account_data: account_data}
        Memento.Query.write(user)
      else
        nil ->
          :user_does_not_exist

        {:error, :invalid_room_id} ->
          :invalid_room_id
      end
    end
    |> Memento.transaction()
    |> case do
      {:ok, :user_does_not_exist} -> {:error, :user_does_not_exist}
      {:ok, :invalid_room_id} -> {:error, :invalid_room_id}
      {:ok, %__MODULE__{}} -> :ok
      error -> error
    end
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
