defmodule RadioBeam.User.Device.Message do
  @moduledoc """
  Functions for Send-to-Device messaging
  """

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
  def put(%Device{} = device, message_attrs, sender_id, type) do
    message = new(message_attrs, sender_id, type)
    messages = Map.update(device.messages, :unsent, [message], &[message | &1])
    put_in(device.messages, messages)
  end

  @doc """
  Returns unsent to-device messages, marking them as sent in the sync response
  that contains the given `since_token`. In the case of an incremental sync,
  an additional, optional `mark_as_read` token can be provided to delete 
  messages that are assumed to be delivered successfully at this point.
  """
  def pop_unsent(%Device{messages: message_map} = device, since_token, mark_as_read \\ nil) do
    # TOIMPL: only take first 100 msgs
    ordered_keys =
      message_map
      |> Stream.map(fn {key, _} -> key end)
      |> Stream.reject(&(&1 == mark_as_read))
      |> Enum.sort_by(
        fn
          :unsent -> 0
          num when is_integer(num) -> num
        end,
        :desc
      )

    desc_ordered_messages =
      ordered_keys
      |> Stream.flat_map(&Map.fetch!(message_map, &1))
      |> Enum.to_list()

    case desc_ordered_messages do
      [] ->
        {:none, device}

      [_ | _] ->
        device = put_in(device.messages, %{since_token => desc_ordered_messages})
        {Enum.reverse(desc_ordered_messages), device}
    end
  end
end
