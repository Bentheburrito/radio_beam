defmodule RadioBeam.User do
  @moduledoc """
  A user registered on this homeserver.
  """
  @types [
    id: :string,
    cross_signing_key_ring: :map,
    last_cross_signing_change_at: :integer,
    room_keys: :map
  ]
  @attrs Keyword.keys(@types)

  @type id() :: String.t()

  defstruct @attrs

  import Ecto.Changeset

  alias RadioBeam.Room
  alias RadioBeam.User.ClientConfig
  alias RadioBeam.User.Database
  alias RadioBeam.User.Device
  alias RadioBeam.User.EventFilter

  @type t() :: %__MODULE__{}

  def new(id) do
    params = %{
      id: id
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

  def exists?(user_id) do
    case Database.fetch_user_account(user_id) do
      {:ok, _} -> true
      _else -> false
    end
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

  def put_device_display_name(user_id, device_id, display_name) do
    Database.update_user_device_with(user_id, device_id, &Device.put_display_name!(&1, display_name))
  end

  @spec put_account_data(id(), Room.id() | :global, String.t(), any()) ::
          {:ok, User.t()} | {:error, :invalid_room_id | :invalid_type | :not_found}
  def put_account_data(user_id, scope, type, content) do
    if exists?(user_id) do
      with {:ok, scope} <- verify_scope(scope),
           {:ok, _config} <-
             Database.upsert_user_client_config_with(user_id, &ClientConfig.put_account_data(&1, scope, type, content)) do
        :ok
      end
    else
      {:error, :not_found}
    end
  end

  defp verify_scope(:global), do: {:ok, :global}

  defp verify_scope("!" <> _rest = room_id) do
    if Room.exists?(room_id), do: {:ok, room_id}, else: {:error, :invalid_room_id}
  end

  def get_account_data(user_id) do
    with {:ok, %ClientConfig{} = config} <- Database.fetch_user_client_config(user_id) do
      {:ok, config.account_data}
    end
  end

  def get_timeline_preferences(user_id, filter_or_filter_id \\ :none) do
    case Database.fetch_user_client_config(user_id) do
      {:ok, config} ->
        ClientConfig.get_timeline_preferences(config, filter_or_filter_id)

      {:error, :not_found} ->
        user_id |> ClientConfig.new!() |> ClientConfig.get_timeline_preferences(filter_or_filter_id)
    end
  end

  ### CLIENT CONFIG ###

  @doc """
  Create and save a new event filter for the given user.
  """
  @spec put_event_filter(id(), raw_filter_definition :: map()) ::
          {:ok, EventFilter.id()} | {:error, :not_found}
  def put_event_filter(user_id, raw_definition) do
    filter = EventFilter.new(raw_definition)

    with {:ok, _config} <- Database.upsert_user_client_config_with(user_id, &ClientConfig.put_event_filter(&1, filter)),
         do: {:ok, filter.id}
  end

  def get_event_filter(user_id, filter_id) do
    with {:ok, config} <- Database.fetch_user_client_config(user_id) do
      ClientConfig.get_event_filter(config, filter_id)
    end
  end
end
