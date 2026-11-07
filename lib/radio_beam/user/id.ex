defmodule RadioBeam.User.ID do
  @moduledoc false

  def server_name("@" <> _ = user_id) do
    case String.split(user_id, ":") do
      [_localpart, server_name] -> {:ok, server_name}
      _else -> {:error, :invalid}
    end
  end
end
