defmodule RadioBeam.OAuth2.Builtin.Guardian do
  use Guardian, otp_app: :radio_beam

  alias RadioBeam.OAuth2.UserDeviceSession
  alias RadioBeam.User

  def subject_for_token(%UserDeviceSession{user: user, device: device}, _claims), do: {:ok, device.id <> user.id}
  def subject_for_token(_, _), do: {:error, :not_a_user}

  def resource_from_claims(%{"sub" => composite_id}), do: lookup_user(composite_id)
  def resource_from_claims(_claims), do: {:error, :not_found}

  defp lookup_user(composite_id) do
    with [device_id, user_id] <- String.split(composite_id, "@", parts: 2),
         {:ok, %User{} = user} <- RadioBeam.Repo.fetch(User, "@" <> user_id) do
      UserDeviceSession.existing_from_user(user, device_id)
    else
      _ -> {:error, :not_found}
    end
  end
end
