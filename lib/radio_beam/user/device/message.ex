defmodule RadioBeam.User.Device.Message do
  @moduledoc """
  Functions for Send-to-Device messaging
  """

  alias RadioBeam.Repo
  alias RadioBeam.User
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

  def expand_device_id(user, "*"), do: user |> User.get_all_devices() |> Enum.map(& &1.id)
  def expand_device_id(_user, device_id), do: [device_id]

  @doc """
  Queues a one-off message to be sent to a particular device when it next sync.
  Must be used in a transaction
  """
  def put(user_id, device_id, %__MODULE__{} = message) do
    put_many([{user_id, device_id, message}])
  end

  def put_many(entries) do
    Repo.transaction(fn ->
      Enum.find_value(entries, {:ok, length(entries)}, fn {user_id, device_id, message} ->
        with {:ok, %User{}} <- persist(user_id, device_id, message), do: false
      end)
    end)
  end

  defp persist(user_id, device_id, %__MODULE__{} = message) do
    with {:ok, user} <- Repo.fetch(User, user_id, lock: :write),
         {:ok, %Device{} = device} <- User.get_device(user, device_id) do
      messages = Map.update(device.messages, :unsent, [message], &[message | &1])
      Repo.insert(put_in(user.device_map[device.id].messages, messages))
    end
  end

  @doc """
  Returns unsent to-device messages, marking them as sent in the sync response
  that contains the given `since_token`. In the case of an incremental sync,
  an additional, optional `mark_as_read` token can be provided to delete 
  messages that are assumed to be delivered successfully at this point.
  """
  def take_unsent(user_id, device_id, since_token, mark_as_read \\ nil) do
    Repo.transaction(fn ->
      {:ok, %User{} = user} = Repo.fetch(User, user_id, lock: :write)
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
          Repo.insert!(put_in(user.device_map[device_id].messages, %{}))
          :none

        [_ | _] ->
          Repo.insert!(put_in(user.device_map[device_id].messages, %{since_token => desc_ordered_messages}))
          {:ok, Enum.reverse(desc_ordered_messages)}
      end
    end)
  end
end
