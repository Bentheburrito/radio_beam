defmodule RadioBeam.User.Device.Message do
  @moduledoc """
  Functions for Send-to-Device messaging
  """

  alias RadioBeam.Repo
  alias RadioBeam.User
  alias RadioBeam.User.Device

  @derive Jason.Encoder
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
  def put(user_id, device_id, %__MODULE__{} = message) do
    put_many([{user_id, device_id, message}])
  end

  def put_many(entries) do
    txn =
      for {user_id, device_id, message} <- entries, into: Repo.Transaction.new() do
        {
          {:put_device_message, user_id, device_id},
          &with({:ok, %User{}} <- persist(user_id, device_id, message), do: {:ok, &1 + 1})
        }
      end

    Repo.Transaction.execute(txn, 0)
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
      {:ok, %Device{messages: messages}} = User.get_device(user, device_id)

      # TOIMPL: only take first 100 msgs
      case Map.pop(messages, :unsent, :none) do
        {:none, ^messages} ->
          :none

        {unsent, messages} ->
          messages = messages |> Map.put(since_token, unsent) |> mark_as_read(mark_as_read)
          Repo.insert!(put_in(user.device_map[device_id].messages, messages))
          {:ok, Enum.reverse(unsent)}
      end
    end)
  end

  def expand_device_id(user, "*"), do: user |> User.get_all_devices() |> Enum.map(& &1.id)
  def expand_device_id(_user, device_id), do: [device_id]

  defp persist(user_id, device_id, %__MODULE__{} = message) do
    with {:ok, user} <- Repo.fetch(User, user_id, lock: :write),
         {:ok, %Device{} = device} <- User.get_device(user, device_id) do
      messages = Map.update(device.messages, :unsent, [message], &[message | &1])
      Repo.insert(put_in(user.device_map[device.id].messages, messages))
    end
  end

  defp mark_as_read(messages, nil), do: messages
  defp mark_as_read(messages, token), do: Map.delete(messages, token)
end
