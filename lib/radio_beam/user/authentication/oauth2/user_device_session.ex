defmodule RadioBeam.User.Authentication.OAuth2.UserDeviceSession do
  @moduledoc false
  alias RadioBeam.Database
  alias RadioBeam.User
  alias RadioBeam.User.Device

  defstruct ~w|user device|a
  @type t() :: %__MODULE__{user: User.t(), device: Device.t()}

  def existing_from_user(%User{} = user, device_id) do
    with {:ok, %Device{} = device} <- User.get_device(user, device_id) do
      {:ok, %__MODULE__{user: user, device: device}}
    end
  end

  def new_from_user!(%User{} = user, device_id, device_opts \\ []) do
    %Device{} =
      device =
      case User.get_device(user, device_id) do
        {:ok, %Device{} = device} -> device
        {:error, :not_found} -> Device.new(device_id, device_opts)
      end

    user = User.put_device(user, device)
    :ok = Database.insert!(user)
    %__MODULE__{user: user, device: device}
  end
end
