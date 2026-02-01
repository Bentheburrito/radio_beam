defmodule RadioBeam.Sync.Source.ToDeviceMessage do
  @moduledoc """
  Returns new and unack'd to-device messages.
  """
  @behaviour RadioBeam.Sync.Source

  alias RadioBeam.PubSub
  alias RadioBeam.Sync.Source
  alias RadioBeam.User

  require Logger

  @impl Source
  def top_level_path(_key, _result), do: ["to_device", "events"]

  @impl Source
  def inputs, do: ~w|user_id device_id|a

  @impl Source
  def run(inputs, key, sink_pid) do
    user_id = inputs.user_id
    device_id = inputs.device_id

    user_id
    |> PubSub.to_device_message_available(device_id)
    |> PubSub.subscribe()

    {maybe_last_batch, next_batch} =
      case Map.get(inputs, :last_batch) do
        nil ->
          {nil, 0}

        num_str ->
          num = String.to_integer(num_str)
          {num, num + 1}
      end

    case User.get_undelivered_to_device_messages(user_id, device_id, next_batch, maybe_last_batch) do
      {:ok, :none} ->
        Source.notify_waiting(sink_pid, key)

        receive do
          {:device_message_available, ^user_id, ^device_id} -> run(inputs, key, sink_pid)
        end

      {:ok, unsent_messages} ->
        {:ok, unsent_messages, next_batch}

      error ->
        Logger.error("error when fetching unsent device messages: #{inspect(error)}")
        {:no_update, next_batch}
    end
  end
end
