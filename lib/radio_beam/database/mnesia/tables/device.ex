defmodule RadioBeam.Database.Mnesia.Tables.Device do
  @moduledoc false

  require Record
  Record.defrecord(:device, __MODULE__, user_device_id_tuple: nil, device: nil)

  @type t() ::
          record(:device,
            user_device_id_tuple: {RadioBeam.User.id(), RadioBeam.Device.id()},
            device: RadioBeam.User.Device.t()
          )

  def opts, do: [attributes: device() |> device() |> Keyword.keys(), type: :set]
end
