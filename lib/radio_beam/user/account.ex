defmodule RadioBeam.User.Account do
  @moduledoc """
  Functions for fetching and putting user account data, including event filters.

  https://spec.matrix.org/latest/client-server-api/#client-config
  """
  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.Database
  alias RadioBeam.User.Device
  alias RadioBeam.User.EventFilter

  def get_timeline_preferences(user_id, filter_or_filter_id \\ :none) do
    with {:ok, user} <- Database.fetch_user(user_id) do
      ignored_user_ids =
        MapSet.new(user.account_data[:global]["m.ignored_user_list"]["ignored_users"] || %{}, &elem(&1, 0))

      preferences = put_filter_if_id_present(%{ignored_user_ids: ignored_user_ids}, user, filter_or_filter_id)

      {:ok, preferences}
    end
  end

  defp put_filter_if_id_present(prefs, user, filter_id) when is_binary(filter_id) do
    case User.get_event_filter(user, filter_id) do
      {:ok, filter} -> Map.put(prefs, :filter, filter)
      {:error, :not_found} -> Map.put(prefs, :filter, EventFilter.new(%{}))
    end
  end

  defp put_filter_if_id_present(prefs, _user, :none), do: prefs
  defp put_filter_if_id_present(prefs, _user, %{} = inline_filter), do: Map.put(prefs, :filter, inline_filter)

  def put_device_display_name(user_id, device_id, display_name) do
    Database.with_user(user_id, fn %User{} = user ->
      with {:ok, %Device{} = device} <- User.get_device(user, device_id) do
        device = Device.put_display_name!(device, display_name)
        user = User.put_device(user, device)
        with :ok <- Database.update_user(user), do: {:ok, user}
      end
    end)
  end

  @doc """
  Create and save a new event filter for the given user.
  """
  @spec upload_filter(User.id(), raw_filter_definition :: map()) :: {:ok, EventFilter.id()} | {:error, :not_found}
  def upload_filter(user_id, raw_definition) do
    filter = EventFilter.new(raw_definition)

    Database.with_user(user_id, fn %User{} = user ->
      user |> User.put_event_filter(filter) |> Database.update_user()
      {:ok, filter.id}
    end)
  end

  @doc """
  Puts user account data (`content`) under the given `scope` and `type`.
  """
  @spec put(User.id(), Room.id() | :global, String.t(), any()) ::
          {:ok, User.t()} | {:error, :invalid_room_id | :invalid_type | :not_found}
  def put(user_id, scope, type, content) do
    Database.with_user(user_id, fn %User{} = user ->
      with {:ok, scope} <- verify_scope(scope),
           {:ok, %User{} = user} <- User.put_account_data(user, scope, type, content) do
        :ok = Database.update_user(user)
        {:ok, user}
      end
    end)
  end

  defp verify_scope(:global), do: {:ok, :global}

  defp verify_scope("!" <> _rest = room_id) do
    if Room.exists?(room_id), do: {:ok, room_id}, else: {:error, :invalid_room_id}
  end
end
