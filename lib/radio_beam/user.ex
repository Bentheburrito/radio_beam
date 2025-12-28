defmodule RadioBeam.User do
  @moduledoc """
  A user registered on this homeserver.
  """
  @types [
    id: :string,
    account_data: :map,
    cross_signing_key_ring: :map,
    last_cross_signing_change_at: :integer,
    room_keys: :map,
    filter_map: :map
  ]
  @attrs Keyword.keys(@types)

  @type id() :: String.t()

  defstruct @attrs

  import Ecto.Changeset

  alias RadioBeam.User.Database
  alias RadioBeam.User.CrossSigningKeyRing
  alias RadioBeam.User.Device
  alias RadioBeam.User.EventFilter
  alias RadioBeam.User.RoomKeys

  @type t() :: %__MODULE__{}

  def new(id) do
    params = %{
      id: id,
      account_data: %{},
      cross_signing_key_ring: CrossSigningKeyRing.new(),
      last_cross_signing_change_at: 0,
      room_keys: RoomKeys.new!(),
      filter_map: %{}
    }

    {%__MODULE__{}, Map.new(@types)}
    |> cast(params, @attrs)
    |> validate_required([:id])
    |> validate_length(:id, max: 255)
    |> validate_user_id()
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

  @doc """
  Puts global or room account data for a user. Any existing content for a
  scope + key is overwritten (not merged). Returns `:ok`
  if the account data was successfully written, and an error tuple otherwise.
  """
  def put_account_data(user, scope \\ :global, type, content)

  @invalid_types ~w|m.fully_read m.push_rules|
  def put_account_data(_user, _scope, type, _content) when type in @invalid_types, do: {:error, :invalid_type}

  def put_account_data(%__MODULE__{} = user, scope, type, content) do
    account_data = RadioBeam.AccessExtras.put_nested(user.account_data, [scope, type], content)
    {:ok, %__MODULE__{user | account_data: account_data}}
  end

  ### DEVICE ###

  @doc "Gets metadata about a user's device"
  @spec get_device_info(id(), Device.id()) :: {:ok, map()} | {:error, :not_found}
  def get_device_info(user_id, device_id) do
    case Database.fetch_user_device(user_id, device_id) do
      {:ok, %Device{id: ^device_id, user_id: ^user_id} = device} -> {:ok, device_info(device)}
      _else -> {:error, :not_found}
    end
  end

  @doc "Gets metadata about all of a user's devices"
  @spec get_all_device_info(id()) :: [map()]
  def get_all_device_info(user_id), do: user_id |> Database.get_all_devices_of_user() |> Enum.map(&device_info/1)

  defp device_info(%Device{} = device), do: Map.take(device, ~w|id display_name last_seen_at last_seen_from_ip|a)

  def put_device_keys(user_id, device_id, opts) do
    case Database.update_user_device_with(user_id, device_id, &Device.put_keys(&1, user_id, opts)) do
      {:ok, %Device{} = device} -> {:ok, Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring)}
      {:error, :invalid_identity_keys} -> {:error, :invalid_user_or_device_id}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def get_undelivered_to_device_messages(user_id, device_id, since, mark_as_read \\ nil) do
    Database.update_user_device_with(user_id, device_id, fn %Device{} = device ->
      {messages_or_none, device} = Device.Message.pop_unsent(device, since, mark_as_read)
      {:ok, device, messages_or_none}
    end)
  end

  # TOIMPL: put device over federation
  def send_to_devices(to_device_message_request, sender_id, message_type) do
    to_device_message_request
    |> parse_send_to_device_request()
    |> Enum.each(fn {user_id, device_id, message} ->
      Database.update_user_device_with(user_id, device_id, &Device.Message.put(&1, message, sender_id, message_type))
    end)
  end

  defp parse_send_to_device_request(request) do
    request
    |> Stream.flat_map(fn {"@" <> _rest = user_id, %{} = device_map} ->
      Stream.map(device_map, fn {device_id_or_glob, message_attrs} ->
        {user_id, device_id_or_glob, message_attrs}
      end)
    end)
    |> Stream.flat_map(fn
      {user_id, "*", message} -> user_id |> Database.get_all_devices_of_user() |> Stream.map(&{user_id, &1.id, message})
      tuple -> [tuple]
    end)
  end

  ### ROOM KEYS ###

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
