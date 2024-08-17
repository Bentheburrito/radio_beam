defmodule RadioBeamWeb.Schemas.InstantMessaging do
  @moduledoc false

  import RadioBeam.Room.InstantMessaging, only: [is_valid_msgtype: 1]

  def message_content(%{"msgtype" => msgtype, "body" => body} = content) when is_valid_msgtype(msgtype) do
    if String.valid?(body), do: {:ok, content}, else: {:error, :invalid}
  end

  def message_content(_value), do: {:error, :invalid}
end
