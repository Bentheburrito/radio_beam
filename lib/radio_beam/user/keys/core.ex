defmodule RadioBeam.User.Keys.Core do
  @moduledoc """
  Functional core for key store operations
  """
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID
  alias RadioBeam.User.CrossSigningKey

  def all_changed_since(membership_event_stream, last_seen_event_by_room_id, since, fetch_keys, get_all_devices_of_user) do
    since_created_at = PaginationToken.created_at(since)

    membership_event_stream
    |> Stream.map(&zip_with_keys_and_latest_id_key_change_at(&1, fetch_keys, get_all_devices_of_user))
    |> Stream.reject(fn {maybe_keys, _, _, _} -> is_nil(maybe_keys) end)
    |> Enum.group_by(
      fn {keys, user_id, last_device_id_key_change_at, _} -> {keys, user_id, last_device_id_key_change_at} end,
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

  defp zip_with_keys_and_latest_id_key_change_at(member_event, fetch_keys, get_all_devices_of_user) do
    user_id = member_event.state_key

    case fetch_keys.(user_id) do
      {:ok, keys} -> {keys, user_id, max_device_id_key_change_at(user_id, get_all_devices_of_user), member_event}
      {:error, :not_found} -> {nil, nil, member_event}
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

  def add_all_keys(key_results, querying_user_id, querying_user_keys, queried_device_ids, all_devices) do
    user_signing_key = querying_user_keys.cross_signing_key_ring.user

    key_results
    |> add_allowed_keys(querying_user_id, querying_user_keys, queried_device_ids, all_devices)
    |> add_csk(["user_signing_keys", querying_user_id], user_signing_key, querying_user_id)
  end

  defp filter_devices(all_devices, queried_device_ids) do
    if Enum.empty?(queried_device_ids), do: all_devices, else: Enum.filter(all_devices, &(&1.id in queried_device_ids))
  end

  def add_allowed_keys(key_results, user_id, user_keys, queried_device_ids, all_devices) do
    devices = filter_devices(all_devices, queried_device_ids)

    key_results
    |> add_csk(["master_keys", user_id], user_keys.cross_signing_key_ring.master, user_id)
    |> add_csk(["self_signing_keys", user_id], user_keys.cross_signing_key_ring.self, user_id)
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
end
