defmodule Fixtures do
  @moduledoc """
  Test fixtures
  """

  alias RadioBeam.ContentRepo.Upload.FileInfo
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

  def file_info(content, type \\ "txt", filename \\ "TestUpload") do
    FileInfo.new(type, byte_size(content), :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower), filename)
  end

  def random_string(num_bytes) do
    for _i <- 1..num_bytes, into: "", do: <<:rand.uniform(26) + ?A - 1>>
  end
end
