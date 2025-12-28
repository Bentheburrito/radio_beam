defmodule RadioBeam.User.Authentication.OAuth2.UserDeviceSession do
  @moduledoc false
  alias RadioBeam.User
  alias RadioBeam.User.Database
  alias RadioBeam.User.Device

  defstruct ~w|user device|a
  @type t() :: %__MODULE__{user: User.t(), device: Device.t()}

  def existing_from_user(%User{} = user, device_id) do
    with {:ok, %Device{} = device} <- Database.fetch_user_device(user.id, device_id) do
      {:ok, %__MODULE__{user: user, device: device}}
    end
  end

  def new_from_user!(%User{} = user, device_id, device_opts \\ []) do
    %Device{} =
      device =
      case Database.fetch_user_device(user.id, device_id) do
        {:ok, %Device{} = device} ->
          device

        {:error, :not_found} ->
          new_device = Device.new(user.id, device_id, device_opts)
          :ok = Database.insert_new_device(new_device)
          new_device
      end

    %__MODULE__{user: user, device: device}
  end
end
