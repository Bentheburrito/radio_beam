defmodule RadioBeam.User.KeyStore.Core do
  @moduledoc """
  Functional core for key store operations
  """
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.User.CrossSigningKey
  alias RadioBeam.User.Device
  alias RadioBeam.User.KeyStore

  def all_changed_since(
        membership_event_stream,
        last_seen_event_by_room_id,
        since,
        fetch_key_store,
        get_all_devices_of_user
      ) do
    since_created_at = PaginationToken.created_at(since)

    membership_event_stream
    |> Stream.map(&zip_with_key_store_and_latest_id_key_change_at(&1, fetch_key_store, get_all_devices_of_user))
    |> Stream.reject(fn {maybe_key_store, _, _, _} -> is_nil(maybe_key_store) end)
    |> Enum.group_by(
      fn {key_store, user_id, last_device_id_key_change_at, _} ->
        {key_store, user_id, last_device_id_key_change_at}
      end,
      fn {_, _, _, member_event} -> member_event end
    )
    |> Enum.reduce(%{changed: MapSet.new(), left: MapSet.new()}, fn
      {{%{last_cross_signing_change_at: lcsca}, user_id, ldikca}, _}, acc
      when lcsca > since_created_at or ldikca > since_created_at ->
        Map.update!(acc, :changed, &MapSet.put(&1, user_id))

      {{_, user_id, _}, member_events}, acc ->
        join_events = Stream.filter(member_events, &(&1.content["membership"] == "join"))
        leave_events = Stream.filter(member_events, &(&1.content["membership"] == "leave"))

        cond do
          # check for any joined members in any room that we did not share before the last sync
          not Enum.empty?(join_events) and
              Enum.all?(join_events, &event_occurred_later?(&1, Map.get(last_seen_event_by_room_id, &1.room_id))) ->
            Map.update!(acc, :changed, &MapSet.put(&1, user_id))

          # check for any user we no longer share a room with, who left since the last sync
          Enum.empty?(join_events) and
              Enum.any?(leave_events, &event_occurred_later?(&1, Map.get(last_seen_event_by_room_id, &1.room_id))) ->
            Map.update!(acc, :left, &MapSet.put(&1, user_id))

          :else ->
            acc
        end
    end)
  end

  defp zip_with_key_store_and_latest_id_key_change_at(member_event, fetch_key_store, get_all_devices_of_user) do
    user_id = member_event.state_key

    case fetch_key_store.(user_id) do
      {:ok, key_store} ->
        {key_store, user_id, max_device_id_key_change_at(user_id, get_all_devices_of_user), member_event}

      {:error, :not_found} ->
        {nil, nil, member_event}
    end
  end

  defp max_device_id_key_change_at(user_id, get_all_devices_of_user) do
    user_id
    |> get_all_devices_of_user.()
    |> Stream.map(& &1.identity_keys_last_updated_at)
    |> Enum.max()
  end

  defp event_occurred_later?(_event, nil), do: false
  defp event_occurred_later?(event, since_event), do: TopologicalID.compare(event.order_id, since_event.order_id) == :gt

  def add_all_keys(key_results, querying_user_id, querying_user_key_store, queried_device_ids, all_devices) do
    user_signing_key = querying_user_key_store.cross_signing_key_ring.user

    key_results
    |> add_allowed_keys(querying_user_id, querying_user_key_store, queried_device_ids, all_devices)
    |> add_csk(["user_signing_keys", querying_user_id], user_signing_key, querying_user_id)
  end

  defp filter_devices(all_devices, queried_device_ids) do
    if Enum.empty?(queried_device_ids), do: all_devices, else: Enum.filter(all_devices, &(&1.id in queried_device_ids))
  end

  def add_allowed_keys(key_results, user_id, user_key_store, queried_device_ids, all_devices) do
    devices = filter_devices(all_devices, queried_device_ids)

    key_results
    |> add_csk(["master_keys", user_id], user_key_store.cross_signing_key_ring.master, user_id)
    |> add_csk(["self_signing_keys", user_id], user_key_store.cross_signing_key_ring.self, user_id)
    |> add_device_keys(user_id, devices)
  end

  defp add_csk(key_results, _path, nil, _user_id), do: key_results

  defp add_csk(key_results, path, %CrossSigningKey{} = key, user_id) do
    RadioBeam.AccessExtras.put_nested(key_results, path, CrossSigningKey.to_map(key, user_id))
  end

  defp add_device_keys(key_results, user_id, devices) do
    for %{id: device_id} = device <- devices, reduce: key_results do
      key_results ->
        RadioBeam.AccessExtras.put_nested(key_results, ["device_keys", user_id, device_id], device.identity_keys)
    end
  end

  def try_put_self_signatures(:none, _signer_user_id, _signer_device_id, _deps), do: %{}

  def try_put_self_signatures(self_signatures, signer_user_id, signer_device_id, deps) do
    self_signatures
    |> Stream.map(fn {key_id_or_device_id, key_params} ->
      case try_update_device_with_signatures(signer_user_id, key_id_or_device_id, key_params, deps) do
        # it's either a CSK key ID or an unknown key ID
        {:error, :not_found} ->
          case try_update_csk_with_signatures(signer_user_id, signer_device_id, key_id_or_device_id, key_params, deps) do
            {:error, error} -> {:error, key_id_or_device_id, error}
            {:ok, _updated_key_store} -> :ok
          end

        {:error, error} ->
          {:error, key_id_or_device_id, error}

        {:ok, _updated_device} ->
          :ok
      end
    end)
    |> Enum.reduce(_failures = %{}, fn
      :ok, failures ->
        failures

      {:error, key_id_or_device_id, error}, failures ->
        RadioBeam.AccessExtras.put_nested(failures, [signer_user_id, key_id_or_device_id], error)
    end)
  end

  defp try_update_device_with_signatures(user_id, maybe_device_id, key_params, deps) do
    deps.update_user_device_with.(user_id, maybe_device_id, fn %Device{} = device ->
      case deps.fetch_key_store.(user_id) do
        {:ok, %KeyStore{cross_signing_key_ring: %{self: %CrossSigningKey{id: ssk_id} = self_signing_key}}} ->
          with :ok <- assert_signature_present(key_params, user_id, "ed25519:#{ssk_id}") do
            Device.put_identity_keys_signature(device, user_id, key_params, self_signing_key)
          end

        {:error, :not_found} ->
          {:error, :signer_has_no_self_csk}
      end
    end)
  end

  defp try_update_csk_with_signatures(signer_user_id, signer_device_id, maybe_key_id, key_params, deps) do
    deps.update_key_store.(signer_user_id, fn %KeyStore{} = key_store ->
      case key_store.cross_signing_key_ring do
        # MSK must be signed by a device...
        %{master: %CrossSigningKey{id: ^maybe_key_id}} ->
          # ...or more specifically, the signer_device_id that is POSTing this request
          try_update_msk_with_device_signature(key_store, signer_user_id, signer_device_id, key_params, deps)

        # the SSK and USK must be signed by the MSK
        %{self: %CrossSigningKey{id: ^maybe_key_id} = ssk} ->
          try_put_user_or_self_signature(signer_user_id, key_store, ssk, key_params)

        %{user: %CrossSigningKey{id: ^maybe_key_id} = usk} ->
          try_put_user_or_self_signature(signer_user_id, key_store, usk, key_params)

        _else ->
          {:error, :signature_key_not_known}
      end
    end)
  end

  defp try_update_msk_with_device_signature(%KeyStore{} = key_store, signer_user_id, signer_device_id, key_params, deps) do
    %CrossSigningKey{} = msk = key_store.cross_signing_key_ring.master
    algo_and_device_id = "ed25519:#{signer_device_id}"

    with :ok <- assert_signature_present(key_params, signer_user_id, algo_and_device_id),
         {:ok, verify_key} <- make_verify_key_from_device(signer_user_id, signer_device_id, algo_and_device_id, deps),
         {:ok, new_msk} <- CrossSigningKey.put_signature(msk, signer_user_id, key_params, signer_user_id, verify_key) do
      {:ok, put_in(key_store.cross_signing_key_ring.master, new_msk)}
    end
  end

  defp assert_signature_present(key_params, signer_user_id, signing_key_id_with_algo) do
    if is_binary(key_params["signatures"][signer_user_id][signing_key_id_with_algo]),
      do: :ok,
      else: {:error, :missing_signature}
  end

  defp make_verify_key_from_device(user_id, device_id, algo_and_device_id, deps) do
    with {:ok, device} <- deps.fetch_user_device.(user_id, device_id),
         %Device{identity_keys: %{"keys" => %{^algo_and_device_id => key}}} <- device do
      {:ok, Polyjuice.Util.make_verify_key(key, algo_and_device_id)}
    else
      _ -> {:error, :signature_key_not_known}
    end
  end

  defp try_put_user_or_self_signature(signer_user_id, key_store, usk_or_ssk, key_params) do
    case key_store.cross_signing_key_ring do
      %{master: %CrossSigningKey{} = msk} ->
        with {:ok, csk} <- CrossSigningKey.put_signature(usk_or_ssk, signer_user_id, key_params, signer_user_id, msk) do
          case csk do
            %CrossSigningKey{usages: ["user"]} -> {:ok, put_in(key_store.cross_signing_key_ring.user, csk)}
            %CrossSigningKey{usages: ["self"]} -> {:ok, put_in(key_store.cross_signing_key_ring.self, csk)}
          end
        end

      _else ->
        {:error, :signature_key_not_known}
    end
  end

  def try_put_others_msk_signatures(others_msk_signatures, signer_user_id, deps) do
    case deps.fetch_key_store.(signer_user_id) do
      {:ok, %KeyStore{cross_signing_key_ring: %{user: %CrossSigningKey{} = signer_usk}}} ->
        others_msk_signatures
        |> flatten_signature_map()
        |> Enum.reduce(_failures = %{}, fn {user_id, keyb64, key_params}, failures ->
          case deps.update_key_store.(
                 user_id,
                 &try_update_master_key_with_usk_signature(&1, user_id, keyb64, key_params, signer_user_id, signer_usk)
               ) do
            {:error, :not_found} -> RadioBeam.AccessExtras.put_nested(failures, [user_id, keyb64], :user_not_found)
            {:error, error} -> RadioBeam.AccessExtras.put_nested(failures, [user_id, keyb64], error)
            {:ok, _} -> failures
          end
        end)

      {:error, :not_found} ->
        for {user_id, key_map} <- others_msk_signatures, {keyb64, _key_params} <- key_map, into: _failures = %{} do
          {user_id, %{keyb64 => :signer_has_no_user_csk}}
        end
    end
  end

  defp flatten_signature_map(signature_map) do
    Stream.flat_map(signature_map, fn {user_id, key_map} ->
      Stream.map(key_map, fn {keyb64, key_params} ->
        {user_id, keyb64, key_params}
      end)
    end)
  end

  defp try_update_master_key_with_usk_signature(user_key_store, user_id, keyb64, key_params, signer_id, signer_usk) do
    case user_key_store do
      %KeyStore{cross_signing_key_ring: %{master: %CrossSigningKey{id: ^keyb64} = user_msk}} ->
        with {:ok, new_user_msk} <- CrossSigningKey.put_signature(user_msk, user_id, key_params, signer_id, signer_usk) do
          {:ok, put_in(user_key_store.cross_signing_key_ring.master, new_user_msk)}
        end

      _master_key_did_not_match ->
        {:error, :signature_key_not_known}
    end
  end
end
