defmodule RadioBeamWeb.Schemas.InstantMessaging do
  @moduledoc false

  @valid_msgtypes Enum.map(~w"text emote notice image file audio location video", &"m.#{&1}")
  def message_content(%{"msgtype" => msgtype, "body" => body} = content) when msgtype in @valid_msgtypes do
    if String.valid?(body), do: {:ok, content}, else: {:error, :invalid}
  end

  def message_content(value),
    do: {:error, :invalid_value, ["msgtype"], {:error, :invalid_enum_value, @valid_msgtypes, value}}
end
