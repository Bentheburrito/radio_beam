defmodule RadioBeam.User.Keys do
  @moduledoc """
  Query a User's Device and CrossSigningKeys

  TODO: move the API fxns from here to RadioBeam.User. Make this module home to
  a domain struct that manages cross signing keys and room backup keys (not
  device keys)

  """
  import RadioBeam.AccessExtras, only: [put_nested: 3]

  alias RadioBeam.User.Database
  alias RadioBeam.Room
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.User
  alias RadioBeam.User.CrossSigningKey
  alias RadioBeam.User.CrossSigningKeyRing
  alias RadioBeam.User.Device

  require Logger

  @type put_signatures_error() :: :unknown_key | :disallowed_key_type | :no_master_csk | :user_not_found

  def claim_otks(user_device_algo_map) do
    user_device_algo_map
    |> Stream.flat_map(fn {user_id, device_algo_map} ->
      Stream.map(device_algo_map, fn {device_id, algo} -> {user_id, device_id, algo} end)
    end)
    |> Enum.reduce(%{}, fn {user_id, device_id, algo}, acc ->
      case Database.update_user_device_with(user_id, device_id, &Device.claim_otk(&1, algo)) do
        {:ok, one_time_key} -> put_nested(acc, [user_id, device_id], one_time_key)
        {:error, :not_found} -> acc
      end
    end)
  end

  def all_changed_since("@" <> _ = user_id, %PaginationToken{} = since) do
    with {:ok, %User{} = user} <- Database.fetch_user(user_id) do
      since_created_at = PaginationToken.created_at(since)

      {shared_memberships_by_user, since_event_map} =
        Database.txn(fn ->
          room_ids = Room.joined(user.id)

          shared_memberships_by_user =
            room_ids
            |> Stream.flat_map(fn room_id ->
              case Room.get_members(room_id, user.id, :latest_visible, &(&1 in ~w|join leave|)) do
                {:ok, member_events} -> Stream.map(member_events, &Map.put(&1, :room_id, room_id))
                _ -> []
              end
            end)
            |> Stream.reject(&(&1.state_key == user.id))
            |> Stream.map(&zip_with_user_and_latest_id_key_change_at/1)
            |> Stream.reject(fn {maybe_user, _, _} -> is_nil(maybe_user) end)
            |> Enum.group_by(
              fn {user, last_device_id_key_change_at, _} -> {user, last_device_id_key_change_at} end,
              fn {_, _, member_event} -> member_event end
            )

          since_event_map =
            Map.new(room_ids, fn room_id ->
              with {:ok, since_event_id} <- PaginationToken.room_last_seen_event_id(since, room_id),
                   {:ok, event_stream} <- Room.View.get_events(room_id, user.id, [since_event_id]),
                   [since_event] <- Enum.take(event_stream, 1) do
                {room_id, since_event}
              end
            end)

          {shared_memberships_by_user, since_event_map}
        end)

      Enum.reduce(shared_memberships_by_user, %{changed: MapSet.new(), left: MapSet.new()}, fn
        {{%{id: user_id, last_cross_signing_change_at: lcsca}, ldikca}, _}, acc
        when lcsca > since_created_at or ldikca > since_created_at ->
          Map.update!(acc, :changed, &MapSet.put(&1, user_id))

        {{user, _}, member_events}, acc ->
          join_events = Stream.filter(member_events, &(&1.content["membership"] == "join"))
          leave_events = Stream.filter(member_events, &(&1.content["membership"] == "leave"))

          cond do
            # check for any joined members in any room that we did not share before the last sync
            not Enum.empty?(join_events) and
                Enum.all?(join_events, &event_occurred_later?(&1, Map.get(since_event_map, &1.room_id))) ->
              Map.update!(acc, :changed, &MapSet.put(&1, user.id))

            # check for any user we no longer share a room with, who left since the last sync
            Enum.empty?(join_events) and
                Enum.any?(leave_events, &event_occurred_later?(&1, Map.get(since_event_map, &1.room_id))) ->
              Map.update!(acc, :left, &MapSet.put(&1, user.id))

            :else ->
              acc
          end
      end)
    end
  end

  defp zip_with_user_and_latest_id_key_change_at(member_event) do
    case Database.fetch_user(member_event.state_key) do
      {:ok, user} -> {user, max_device_id_key_change_at(user.id), member_event}
      {:error, :not_found} -> {nil, nil, member_event}
    end
  end

  defp max_device_id_key_change_at(user_id) do
    user_id
    |> Database.get_all_devices_of_user()
    |> Stream.map(& &1.identity_keys_last_updated_at)
    |> Enum.max()
  end

  defp event_occurred_later?(_event, nil), do: false
  defp event_occurred_later?(event, since_event), do: TopologicalID.compare(event.order_id, since_event.order_id) == :gt

  @doc """
  Queries all local users' keys by the given map of %{user_id => [device_id]}.
  Only signatures the given `user_id` is allowed to view will be included.
  """
  @spec query_all(%{User.id() => [Device.id()]}, User.id()) :: map()
  def query_all(query_map, querying_user_id) do
    Database.with_user(querying_user_id, fn %User{} = querying_user ->
      Enum.reduce(query_map, %{}, fn
        {^querying_user_id, device_ids}, key_results ->
          add_authz_keys(key_results, querying_user, querying_user, device_ids)

        {user_id, device_ids}, key_results ->
          case Database.fetch_user(user_id) do
            {:error, :not_found} -> key_results
            {:ok, user} -> add_authz_keys(key_results, user, device_ids)
          end
      end)
    end)
  end

  defp add_authz_keys(key_results, %{id: id} = user, %{id: id}, device_ids) do
    key_results
    |> add_authz_keys(user, device_ids)
    |> add_csk(["user_signing_keys", user.id], user.cross_signing_key_ring.user, user.id)
  end

  defp add_authz_keys(key_results, user, device_ids) do
    key_results
    |> add_csk(["master_keys", user.id], user.cross_signing_key_ring.master, user.id)
    |> add_csk(["self_signing_keys", user.id], user.cross_signing_key_ring.self, user.id)
    |> add_device_keys(user, device_ids)
  end

  defp add_csk(key_results, _path, nil, _user_id), do: key_results

  defp add_csk(key_results, path, %CrossSigningKey{} = key, user_id) do
    RadioBeam.AccessExtras.put_nested(key_results, path, CrossSigningKey.to_map(key, user_id))
  end

  defp add_device_keys(key_results, user, device_ids) do
    devices = Database.get_all_devices_of_user(user.id)

    for %{id: device_id} = device <- devices, Enum.empty?(device_ids) or device_id in device_ids, reduce: key_results do
      key_results ->
        RadioBeam.AccessExtras.put_nested(key_results, ["device_keys", user.id, device_id], device.identity_keys)
    end
  end

  @spec put_signatures(User.id(), map()) ::
          :ok
          | {:error,
             %{String.t() => %{String.t() => put_signatures_error() | CrossSigningKey.put_signature_error()}}
             | :signer_has_no_user_csk}
  def put_signatures(signer_user_id, user_key_map) do
    {self_signatures, others_signatures} = Map.pop(user_key_map, signer_user_id)

    result =
      Database.with_user(signer_user_id, fn
        signer when map_size(others_signatures) == 0 or not is_nil(signer.cross_signing_key_ring.user) ->
          case Map.merge(put_self_signatures(self_signatures, signer), put_others_signatures(others_signatures, signer)) do
            failures when map_size(failures) == 0 -> :ok
            failures -> {:error, failures}
          end

        _ ->
          {:error, :signer_has_no_user_csk}
      end)

    with {:error, :not_found} <- result, do: {:error, :signer_has_no_user_csk}
  end

  defp put_self_signatures(nil, %User{}), do: %{}

  defp put_self_signatures(self_signatures, %User{id: user_id} = user) do
    Enum.reduce(self_signatures, _failures = %{}, fn {key_or_device_id, key_params}, failures ->
      key_params["signatures"][user_id]
      |> Stream.map(fn {keyb64, _signature} ->
        with {:ok, verify_key} <- make_verify_key(user.cross_signing_key_ring, keyb64, user_id) do
          put_self_signature(user, key_or_device_id, key_params, verify_key)
        end
      end)
      |> Enum.reduce(failures, fn
        {:ok, %User{} = user}, failures ->
          Database.update_user(user)
          failures

        {:ok, %Device{} = device}, failures ->
          # TOFIX: not atomic....
          Database.update_user_device_with(device.user_id, device.id, fn _old_device -> device end)
          failures

        {:error, error}, failures ->
          RadioBeam.AccessExtras.put_nested(failures, [user.id, key_or_device_id], error)
      end)
    end)
  end

  defp make_verify_key(key_ring, "ed25519:" <> id = keyb64, user_id) do
    case get_csk_or_device_by_id(key_ring, id, user_id) do
      %CrossSigningKey{} = csk -> {:ok, csk}
      %Device{identity_keys: %{"keys" => %{^keyb64 => key}}} -> {:ok, Polyjuice.Util.make_verify_key(key, keyb64)}
      nil -> {:error, :unknown_key}
    end
  end

  defp put_self_signature(user, key_or_device_id, key_params, verify_key) do
    case get_csk_or_device_by_id(user.cross_signing_key_ring, key_or_device_id, user.id) do
      %CrossSigningKey{} = csk ->
        with {:ok, new_master_csk} <- CrossSigningKey.put_signature(csk, user.id, key_params, user.id, verify_key) do
          {:ok, put_in(user.cross_signing_key_ring.master, new_master_csk)}
        end

      %Device{} = device ->
        updater = &Device.put_identity_keys_signature(&1, user.id, key_params, verify_key)

        Database.update_user_device_with(user.id, device.id, updater)
    end
  end

  defp put_others_signatures(others_signatures, signer) do
    user_ids = Map.keys(others_signatures)

    Database.with_all_users(user_ids, fn user_list ->
      user_map = Map.new(user_list, &{&1.id, &1})

      others_signatures
      |> Stream.flat_map(fn {user_id, key_map} ->
        Stream.map(key_map, fn {keyb64, key_params} -> {user_id, keyb64, key_params} end)
      end)
      |> Stream.map(&put_others_signature(&1, signer, user_map))
      |> Enum.reduce(_failures = %{}, fn
        {:ok, %User{} = user}, failures ->
          Database.update_user(user)
          failures

        {:error, {user_id, keyb64, error}}, failures ->
          RadioBeam.AccessExtras.put_nested(failures, [user_id, keyb64], error)
      end)
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

  defp get_csk_or_device_by_id(key_ring, key_or_device_id, user_id) do
    case CrossSigningKeyRing.get_key_by_id(key_ring, key_or_device_id) do
      %CrossSigningKey{} = csk -> csk
      nil -> user_id |> Database.fetch_user_device(key_or_device_id) |> with_default(nil)
    end
  end

  defp with_default({:ok, value}, _default), do: value
  defp with_default(_non_ok_val, default), do: default
end
