defmodule RadioBeam.User.Authentication.OAuth2.Builtin.Guardian do
  @moduledoc false
  use Guardian, otp_app: :radio_beam

  alias RadioBeam.User.Device

  def subject_for_token(%Device{user_id: user_id} = device, _claims), do: {:ok, device.id <> user_id}
  def subject_for_token(_, _), do: {:error, :not_a_user}

  def resource_from_claims(%{"sub" => composite_id}), do: lookup_user(composite_id)
  def resource_from_claims(_claims), do: {:error, :not_found}

  defp lookup_user(composite_id) do
    case String.split(composite_id, "@", parts: 2) do
      [device_id, user_id] -> RadioBeam.User.Database.fetch_user_device("@" <> user_id, device_id)
      _ -> {:error, :not_found}
    end
  end
end
