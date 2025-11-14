defmodule RadioBeam.User.RoomKeys.Backup.KeyData do
  @moduledoc """
  `RoomKeyBackup` data in the spec; encrypted session info
  """
  @attrs ~w|first_message_index forwarded_count session_data verified?|a
  @enforce_keys @attrs
  defstruct @attrs

  def new!(%{"first_message_index" => fmi, "forwarded_count" => fc, "session_data" => sd, "is_verified" => v}) do
    %__MODULE__{first_message_index: fmi, forwarded_count: fc, session_data: sd, verified?: v}
  end

  def compare(%__MODULE__{} = kd1, %__MODULE__{} = kd2) do
    kd1_verified_as_int = if kd1.verified?, do: 0, else: 1
    kd2_verified_as_int = if kd2.verified?, do: 0, else: 1

    kd1_tuple = {kd1_verified_as_int, kd1.first_message_index, kd1.forwarded_count}
    kd2_tuple = {kd2_verified_as_int, kd2.first_message_index, kd2.forwarded_count}

    cond do
      kd1_tuple < kd2_tuple -> :lt
      kd1_tuple == kd2_tuple -> :eq
      :else -> :gt
    end
  end

  defimpl Jason.Encoder do
    def encode(key_data, opts) do
      Jason.Encode.map(
        %{
          "first_message_index" => key_data.first_message_index,
          "forwarded_count" => key_data.forwarded_count,
          "session_data" => key_data.session_data,
          "is_verified" => key_data.verified?
        },
        opts
      )
    end
  end
end
