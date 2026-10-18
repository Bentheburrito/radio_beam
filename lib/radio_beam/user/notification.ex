defmodule RadioBeam.User.Notification do
  @moduledoc """
  A user notification triggered by a room event
  """
  defstruct ~w|user_id actions event profile_tag read room_id ts|a

  @opaque t() :: %__MODULE__{}

  def new(user_id, actions, event, profile_tag, read, room_id, ts),
    do: %__MODULE__{
      user_id: user_id,
      actions: actions,
      event: event,
      profile_tag: profile_tag,
      read: read,
      room_id: room_id,
      ts: ts
    }

  def with_profile_tag(%__MODULE__{} = notification, profile_tag), do: put_in(notification.profile_tag, profile_tag)

  defimpl JSON.Encoder do
    def encode(notification, encoder) do
      notification
      |> Map.from_struct()
      |> Map.take(~w|actions event profile_tag read room_id ts|a)
      |> JSON.Encoder.Map.encode(encoder)
    end
  end
end
