defmodule RadioBeam.Device do
  @moduledoc """
  A user's device. A device has an entry in this table for every pair of 
  access/refresh tokens.
  """

  @typedoc """
  The status of a device's pair of access/refresh tokens.

  - `:active` means the tokens are currently in use
  - `:pending` means the tokens have been given to the client, but are waiting
  to be used before they become active

  If a pair of tokens become inactive/are invalidated (as in a user logs out), 
  they should be simply deleted from the table.
  """
  @type status :: :active | :pending
  @statuses [:active, :pending]

  # note: this is a KW list, because map keys are unordered
  @types [
    id: :string,
    user_id: :string,
    display_name: :string,
    access_token: :string,
    refresh_token: :string,
    expires_at: :utc_datetime,
    status: Ecto.ParameterizedType.init(Ecto.Enum, values: @statuses)
  ]
  @attrs Keyword.keys(@types)

  # TODO: should probably rethink the way tokens are refreshed and change this into a set, 
  # because we need to invalidate current tokens when a device with the same ID is registered
  use Memento.Table,
    attributes: @attrs,
    index: [:user_id, :access_token, :refresh_token],
    type: :bag

  import Ecto.Changeset

  alias Ecto.Changeset

  @type t() :: %__MODULE__{}

  @spec new(params :: map()) :: {:ok, t()} | {:error, Changeset.t()}
  def new(params) do
    params = put_default_values(params)

    {%__MODULE__{}, Map.new(@types)}
    |> cast(params, @attrs)
    |> validate_required(@attrs)
    |> validate_inclusion(:status, @statuses)
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

  def generate_token, do: Ecto.UUID.generate()
  def default_device_name, do: "New Device (added #{Date.to_string(Date.utc_today())})"
end
