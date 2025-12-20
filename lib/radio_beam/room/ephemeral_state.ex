defmodule RadioBeam.Room.EphemeralState do
  @moduledoc false
  alias RadioBeam.Room.EphemeralState.Core
  alias RadioBeam.Room.EphemeralState.Server

  defstruct actively_typing: %{}

  @type t() :: %__MODULE__{actively_typing: %{RadioBeam.User.id() => :timer.tref()}}

  def put_typing(room_id, user_id, timeout \\ Core.max_timeout_ms()), do: Server.put_typing(room_id, user_id, timeout)

  def all_typing(room_id), do: Server.all_typing(room_id)

  def delete_typing(room_id, user_id), do: Server.delete_typing(room_id, user_id)
end
