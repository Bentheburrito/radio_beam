defmodule RadioBeam.User.Notifications.Core.Pusher do
  @moduledoc """
  A notification Pusher as defined by [the
  spec](https://spec.matrix.org/v1.18/client-server-api/#post_matrixclientv3pushersset)
  """
  alias RadioBeam.User.Notifications.Core.Pusher.Data, as: PusherData

  @attrs ~w|app_id pushkey app_display_name data device_display_name profile_tag lang|a
  @enforce_keys @attrs
  defstruct @attrs

  def new(kind, app_id, pushkey, app_display_name, data, device_display_name, opts \\ []) do
    profile_tag = Keyword.get(opts, :profile_tag)

    with :ok <- validate_app_id(app_id),
         :ok <- validate_pushkey(pushkey),
         :ok <- validate_user_string(app_display_name, :app_display_name),
         :ok <- validate_user_string(device_display_name, :device_display_name),
         :ok <- validate_user_string(profile_tag || "", :profile_tag),
         {:ok, %PusherData{} = pusher_data} <- PusherData.new(kind, data) do
      lang = Keyword.get(opts, :lang, "en")

      {:ok,
       %__MODULE__{
         app_id: app_id,
         pushkey: pushkey,
         app_display_name: app_display_name,
         data: pusher_data,
         device_display_name: device_display_name,
         profile_tag: profile_tag,
         lang: lang
       }}
    end
  end

  defp validate_app_id(app_id) do
    if is_binary(app_id) and String.length(app_id) <= 64, do: :ok, else: {:error, :app_id}
  end

  defp validate_pushkey(pushkey) when is_binary(pushkey) and byte_size(pushkey) <= 512, do: :ok
  defp validate_pushkey(_pushkey), do: {:error, :pushkey}

  @max_user_string_limit 2 ** 10
  defp validate_user_string(str, _field) when is_binary(str) and byte_size(str) <= @max_user_string_limit, do: :ok
  defp validate_user_string(_invalid_str, field), do: {:error, field}
end
