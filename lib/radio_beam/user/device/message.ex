defmodule RadioBeam.User.Device.Message do
  @moduledoc """
  Functions for Send-to-Device messaging
  """

  alias RadioBeam.User
  alias RadioBeam.User.Database
  alias RadioBeam.User.Device

  @derive JSON.Encoder
  @enforce_keys [:content, :sender, :type]
  defstruct content: nil, sender: nil, type: nil
  @type t() :: %__MODULE__{}

  @doc """
  Create a new %Device.Message{}

  iex> RadioBeam.User.Device.Message.new(%{"content" => "test"}, "@someone:somewhere", "com.msg.type")
  %RadioBeam.User.Device.Message{content: %{"content" => "test"}, sender: "@someone:somewhere", type: "com.msg.type"}
  """
  def new(content, sender, type) do
    %__MODULE__{content: content, sender: sender, type: type}
  end

  @doc """
  Queues a one-off message to be sent to a particular device when it next sync.
  Must be used in a transaction
  """
  def put(user_id, device_id, message, sender_id, type) do
    put_many(%{user_id => %{device_id => message}}, sender_id, type)
  end

  def put_many(nil, _sender_id, _type), do: {:error, :no_message}
  def put_many(empty, _sender_id, _type) when map_size(empty) == 0, do: :ok

  def put_many(put_request, sender_id, type) do
    Database.txn(fn ->
      put_request
      |> parse_request(sender_id, type)
      |> Enum.find_value(:ok, fn {user, device_id, message} ->
        with :ok <- persist(user, device_id, message), do: false
      end)
    end)
  end

  defp persist(user, device_id, %__MODULE__{} = message) do
    with {:ok, %Device{} = device} <- User.get_device(user, device_id) do
      messages = Map.update(device.messages, :unsent, [message], &[message | &1])
      Database.update_user(put_in(user.device_map[device.id].messages, messages))
    end
  end

  defp parse_request(request, sender_id, type) do
    request
    |> Stream.flat_map(fn {"@" <> _rest = user_id, %{} = device_map} ->
      Stream.map(device_map, fn {device_id_or_glob, msg_content} ->
        {user_id, device_id_or_glob, Device.Message.new(msg_content, sender_id, type)}
      end)
    end)
    |> Stream.flat_map(fn {user_id, device_id_or_glob, message} ->
      # this should take a write lock...
      case Database.fetch_user(user_id) do
        {:ok, %User{} = user} -> user |> expand_device_id(device_id_or_glob) |> Stream.map(&{user, &1, message})
        # TODO: raise if user not found?
        # TOIMPL: put device over federation
        {:error, :not_found} -> []
      end
    end)
  end

  defp expand_device_id(user, "*"), do: user |> User.get_all_devices() |> Enum.map(& &1.id)
  defp expand_device_id(_user, device_id), do: [device_id]

  @doc """
  Returns unsent to-device messages, marking them as sent in the sync response
  that contains the given `since_token`. In the case of an incremental sync,
  an additional, optional `mark_as_read` token can be provided to delete 
  messages that are assumed to be delivered successfully at this point.
  """
  def take_unsent(user_id, device_id, since_token, mark_as_read \\ nil) do
    Database.txn(fn ->
      # TODO: this should take a write lock
      {:ok, %User{} = user} = Database.fetch_user(user_id)
      {:ok, %Device{messages: message_map}} = User.get_device(user, device_id)

      # TOIMPL: only take first 100 msgs
      ordered_keys =
        message_map
        |> Stream.map(fn {key, _} -> key end)
        |> Stream.reject(&(&1 == mark_as_read))
        |> Enum.sort_by(
          fn
            :unsent -> 0
            %{created_at_ms: created_at_ms} -> created_at_ms
          end,
          :desc
        )

      desc_ordered_messages =
        ordered_keys
        |> Stream.flat_map(&Map.fetch!(message_map, &1))
        |> Enum.to_list()

      case desc_ordered_messages do
        [] ->
          Database.update_user(put_in(user.device_map[device_id].messages, %{}))
          :none

        [_ | _] ->
          Database.update_user(put_in(user.device_map[device_id].messages, %{since_token => desc_ordered_messages}))
          {:ok, Enum.reverse(desc_ordered_messages)}
      end
    end)
  end
end
