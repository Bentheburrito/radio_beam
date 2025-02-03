defmodule RadioBeam.User.Keys do
  @moduledoc """
  Query a User's Device and CrossSigningKeys
  """
  alias RadioBeam.User.CrossSigningKeyRing
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

  def put_signatures(signer_user_id, user_key_map) do
    {self_signatures, others_signatures} = Map.pop(user_key_map, signer_user_id)

    Repo.one_shot(fn ->
      with {:ok, signer} when not is_nil(signer.cross_signing_key_ring.user) <- User.get(signer_user_id) do
        _failures =
          Map.merge(put_self_signatures(self_signatures, signer), put_others_signatures(others_signatures, signer))
      else
        _ -> {:error, :signer_has_no_user_csk}
      end
    end)
  end

  defp put_self_signatures(nil, %User{}), do: %{}

  defp put_self_signatures(self_signatures, %User{id: user_id} = user) do
    {:ok, devices} = Device.get_all_by_user(user.id)

    Enum.reduce(self_signatures, _failures = %{}, fn {key_or_device_id, key_params}, failures ->
      key_params["signatures"][user_id]
      |> Stream.map(fn {keyb64, _signature} ->
        with {:ok, verify_key} <- make_verify_key(user.cross_signing_key_ring, keyb64, devices) do
          put_self_signature(user, devices, key_or_device_id, key_params, verify_key)
        end
      end)
      |> Enum.reduce(failures, fn
        {:ok, %User{} = user}, failures ->
          Memento.Query.write(user)
          failures

        {:ok, %Device{} = device}, failures ->
          Device.Table.persist(device)
          failures

        {:error, error}, failures ->
          RadioBeam.put_nested(failures, [user.id, key_or_device_id], error)
      end)
    end)
  end

  defp make_verify_key(key_ring, "ed25519:" <> id = keyb64, devices) do
    case get_csk_or_device_by_id(key_ring, id, devices) do
      %CrossSigningKey{} = csk -> {:ok, csk}
      %Device{identity_keys: %{"keys" => %{^keyb64 => key}}} -> {:ok, Polyjuice.Util.make_verify_key(key, keyb64)}
      nil -> {:error, :unknown_key}
    end
  end

  defp put_self_signature(user, devices, key_or_device_id, key_params, verify_key) do
    case get_csk_or_device_by_id(user.cross_signing_key_ring, key_or_device_id, devices) do
      %CrossSigningKey{} = csk ->
        with {:ok, new_master_csk} <- CrossSigningKey.put_signature(csk, user.id, key_params, user.id, verify_key) do
          {:ok, put_in(user.cross_signing_key_ring.master, new_master_csk)}
        end

      %Device{} = device ->
        with {:ok, new_identity_key} <- Device.put_identity_keys_signature(device, key_params, verify_key) do
          {:ok, put_in(device.identity_keys, new_identity_key)}
        end
    end
  end

  defp put_others_signatures(others_signatures, signer) do
    user_map = others_signatures |> Map.keys() |> User.all() |> Map.new(&{&1.id, &1})

    others_signatures
    |> Stream.flat_map(fn {user_id, key_map} ->
      Stream.map(key_map, fn {keyb64, key_params} -> {user_id, keyb64, key_params} end)
    end)
    |> Stream.map(&put_others_signature(&1, signer, user_map))
    |> Enum.reduce(_failures = %{}, fn
      {:ok, %User{} = user}, failures ->
        Memento.Query.write(user)
        failures

      {:error, {user_id, keyb64, error}}, failures ->
        RadioBeam.put_nested(failures, [user_id, keyb64], error)
    end)
  end

  defp put_others_signature({user_id, keyb64, key_params}, signer, user_map) do
    case Map.fetch(user_map, user_id) do
      {:ok, %User{cross_signing_key_ring: %{master: %CrossSigningKey{id: ^keyb64}}} = user} ->
        case CrossSigningKey.put_signature(
               user.cross_signing_key_ring.master,
               user.id,
               key_params,
               signer.id,
               signer.cross_signing_key_ring.user
             ) do
          {:ok, new_master_csk} ->
            {:ok, put_in(user.cross_signing_key_ring.master, new_master_csk)}

          {:error, error} ->
            {:error, {user_id, keyb64, error}}
        end

      {:ok, %User{cross_signing_key_ring: %{master: %CrossSigningKey{}}}} ->
        {:error, {user_id, keyb64, :disallowed_key_type}}

      {:ok, _user_no_master_csk} ->
        {:error, {user_id, keyb64, :no_master_csk}}

      :error ->
        {:error, {user_id, keyb64, :user_not_found}}
    end
  end

  defp get_csk_or_device_by_id(key_ring, key_or_device_id, devices) do
    case CrossSigningKeyRing.get_key_by_id(key_ring, key_or_device_id) do
      %CrossSigningKey{} = csk -> csk
      nil -> Enum.find(devices, %{}, &(&1.id == key_or_device_id))
    end
  end
end
