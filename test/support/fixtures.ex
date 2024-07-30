defmodule Fixtures do
  @moduledoc """
  Test fixtures
  """

  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.Device
  alias RadioBeam.User

  def strong_password, do: "Asdf123$"

  def user(user_id \\ "localhost" |> UserIdentifier.generate() |> to_string()) do
    {:ok, user} = User.new(user_id, strong_password())
    Memento.transaction!(fn -> Memento.Query.write(user) end)
  end

  def device(user_id, display_name \\ Device.default_device_name()) do
    {:ok, device} =
      Device.new(%{
        id: Device.generate_token(),
        user_id: user_id,
        display_name: display_name,
        access_token: Device.generate_token(),
        refresh_token: Device.generate_token()
      })

    Memento.transaction!(fn -> Memento.Query.write(device) end)
  end

  def write!(struct), do: Memento.transaction!(fn -> Memento.Query.write(struct) end)
end
