defmodule RadioBeam.OAuth2.UserDeviceSession do
  alias RadioBeam.Repo
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
    %Device{} = device = Device.new(device_id, device_opts)
    %User{} = user = user |> User.put_device(device) |> Repo.insert!()
    %__MODULE__{user: user, device: device}
  end
end
