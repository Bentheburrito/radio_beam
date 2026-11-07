defmodule RadioBeam.User.Authentication.ClientServerRequest do
  @moduledoc """
  An authenticated Client-Server API request.
  """

  defstruct ~w|user_id device_id server_name|a

  def new!(user_id, device_id, server_name),
    do: %__MODULE__{user_id: user_id, device_id: device_id, server_name: server_name}
end
