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
    device = Device.new(user_id, display_name: display_name)
    Memento.transaction!(fn -> Device.persist(device) end)
  end

  def write!(%Device{} = device), do: Memento.transaction!(fn -> Device.persist(device) end)
  def write!(struct), do: Memento.transaction!(fn -> Memento.Query.write(struct) end)
end
