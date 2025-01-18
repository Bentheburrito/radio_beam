defmodule RadioBeam.User.Keys do
  @moduledoc """
  Query a User's Device and CrossSigningKeys
  """
  alias RadioBeam.Device
  alias RadioBeam.User
  alias RadioBeam.User.CrossSigningKey
  alias RadioBeam.Repo

  require Logger

  @doc """
  Queries all local users' keys by the given map of %{user_id => [device_id]}.
  Only signatures the given `user_id` is allowed to view will be included.
  """
  @spec query_all(%{User.id() => [Device.id()]}, User.id()) :: map()
  def query_all(query_map, querying_user_id) do
    Repo.one_shot(fn ->
      with {:ok, querying_user} <- User.get(querying_user_id) do
        Enum.reduce(query_map, %{}, fn
          {^querying_user_id, device_ids}, key_results ->
            add_authz_keys(key_results, querying_user, querying_user, device_ids)

          {user_id, device_ids}, key_results ->
            case User.get(user_id) do
              {:error, :not_found} -> key_results
              {:ok, user} -> add_authz_keys(key_results, user, device_ids)
            end
        end)
      end
    end)
  end

  defp add_authz_keys(key_results, %{id: id} = user, %{id: id}, device_ids) do
    key_results
    |> add_authz_keys(user, device_ids)
    |> put_csk(["user_signing_keys", user.id], user.cross_signing_key_ring.user, user.id)
  end

  defp add_authz_keys(key_results, user, device_ids) do
    key_results
    # TODO: strip signatures the user is not allowed to see
    |> put_csk(["master_keys", user.id], user.cross_signing_key_ring.master, user.id)
    |> put_csk(["self_signing_keys", user.id], user.cross_signing_key_ring.self, user.id)
    |> put_device_keys(user.id, device_ids)
  end

  defp put_csk(key_results, _path, nil, _user_id), do: key_results

  defp put_csk(key_results, path, %CrossSigningKey{} = key, user_id) do
    RadioBeam.put_nested(key_results, path, CrossSigningKey.to_map(key, user_id))
  end

  defp put_device_keys(key_results, user_id, device_ids) do
    case Device.get_all_by_user(user_id) do
      {:ok, devices} ->
        for %{id: device_id} = device <- devices,
            Enum.empty?(device_ids) or device_id in device_ids,
            reduce: key_results do
          key_results -> RadioBeam.put_nested(key_results, ["device_keys", user_id, device_id], device.identity_keys)
        end

      {:error, error} ->
        Logger.error("Failed to get devices by user ID #{inspect(user_id)} while querying devices: #{inspect(error)}")
        key_results
    end
  end
end
