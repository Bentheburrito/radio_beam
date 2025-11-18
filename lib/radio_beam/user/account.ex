defmodule RadioBeam.User.Account do
  @moduledoc """
  Functions for fetching and putting user account data, including event filters.

  https://spec.matrix.org/latest/client-server-api/#client-config
  """
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.Device
  alias RadioBeam.User.EventFilter

  def put_device_display_name(user_id, device_id, display_name) do
    Repo.transaction(fn ->
      with {:ok, %User{} = user} <- Repo.fetch(User, user_id, lock: :write),
           {:ok, %Device{} = device} <- User.get_device(user, device_id) do
        device = Device.put_display_name!(device, display_name)
        user |> User.put_device(device) |> Repo.insert()
      end
    end)
  end

  @doc """
  Create and save a new event filter for the given user.
  """
  @spec upload_filter(User.id(), raw_filter_definition :: map()) :: {:ok, EventFilter.id()} | {:error, :not_found}
  def upload_filter(user_id, raw_definition) do
    filter = EventFilter.new(raw_definition)

    Repo.transaction(fn ->
      with {:ok, %User{} = user} <- Repo.fetch(User, user_id, lock: :write) do
        user |> User.put_event_filter(filter) |> Repo.insert!()
        {:ok, filter.id}
      end
    end)
  end

  @doc """
  Puts user account data (`content`) under the given `scope` and `type`.
  """
  @spec put(User.id(), Room.id() | :global, String.t(), any()) ::
          {:ok, User.t()} | {:error, :invalid_room_id | :invalid_type | :not_found}
  def put(user_id, scope, type, content) do
    Repo.transaction(fn ->
      with {:ok, %User{} = user} <- Repo.fetch(User, user_id, lock: :write),
           {:ok, scope} <- verify_scope(scope),
           {:ok, %User{} = user} <- User.put_account_data(user, scope, type, content) do
        Repo.insert(user)
      end
    end)
  end

  defp verify_scope(:global), do: {:ok, :global}

  defp verify_scope("!" <> _rest = room_id) do
    case Repo.fetch(Room, room_id) do
      {:ok, %Room{}} -> {:ok, room_id}
      {:error, _} -> {:error, :invalid_room_id}
    end
  end
end
