defmodule RadioBeam.Device do
  @moduledoc """
  A user's device. A device has an entry in this table for every pair of 
  access/refresh tokens.
  """

  # note: this is a KW list, because map keys are unordered
  @types [
    id: :string,
    user_id: :string,
    display_name: :string,
    access_token: :string,
    refresh_token: :string,
    prev_refresh_token: :string,
    expires_at: :utc_datetime
  ]
  @attrs Keyword.keys(@types)

  use Memento.Table,
    attributes: @attrs,
    index: [:user_id, :access_token, :refresh_token, :prev_refresh_token],
    type: :set

  import Ecto.Changeset

  alias Ecto.Changeset

  @typedoc """
  A user's device.

  `prev_refresh_token` will be `nil` most of the time. It will only have
  the previos refresh token for a limited window of time: from the time a 
  client refreshes its device's tokens, to the new token's first use.

  "The old refresh token remains valid until the new access token or refresh 
  token is used, at which point the old refresh token is revoked. This ensures 
  that if a client fails to receive or persist the new tokens, it will be able 
  to repeat the refresh operation."
  """
  @type t() :: %__MODULE__{}

  @spec new(params :: map()) :: {:ok, t()} | {:error, Changeset.t()}
  def new(params) do
    params = put_default_values(params)

    {%__MODULE__{}, Map.new(@types)}
    |> cast(params, @attrs)
    |> validate_required(List.delete(@attrs, :prev_refresh_token))
    |> validate_change(:user_id, fn :user_id, user_id ->
      case RadioBeam.Repo.get(RadioBeam.User, user_id) do
        {:ok, nil} -> [user_id: "'#{inspect(user_id)}' does not exist"]
        {:ok, _} -> []
      end
    end)
    |> apply_action(:update)
  end

  # one day before token needs to be refreshed, or 1 week if client doesn't 
  # support refresh tokens
  @refreshable_ms 24 * 60 * 60 * 1000
  @non_refreshable_ms @refreshable_ms * 7
  defp put_default_values(params) do
    now = DateTime.utc_now()

    expires_in_ms =
      if is_map_key(params, :refresh_token) or is_map_key(params, "refresh_token") do
        @refreshable_ms
      else
        @non_refreshable_ms
      end

    if params |> Map.keys() |> List.first() |> is_binary() do
      Map.put(params, "expires_at", DateTime.add(now, expires_in_ms, :millisecond))
    else
      Map.put(params, :expires_at, DateTime.add(now, expires_in_ms, :millisecond))
    end
  end

  @spec by_access_token(access_token :: binary()) :: {:ok, t()} | {:error, :not_found}
  def by_access_token(access_token) do
    fn -> Memento.Query.select(__MODULE__, {:==, :access_token, access_token}, limit: 1) end
    |> Memento.transaction()
    |> case do
      {:ok, [device]} -> {:ok, device}
      {:ok, []} -> {:error, :not_found}
    end
  end

  def generate_token, do: Ecto.UUID.generate()
  def default_device_name, do: "New Device (added #{Date.to_string(Date.utc_today())})"
end
