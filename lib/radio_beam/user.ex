defmodule RadioBeam.User do
  @moduledoc """
  A user registered on this homeserver.
  """
  @types [id: :string, pwd_hash: :string, registered_at: :utc_datetime]
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
      registered_at: DateTime.utc_now()
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
