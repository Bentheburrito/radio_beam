defmodule RadioBeamWeb.SyncController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2]

  require Logger

  alias RadioBeam.User
  alias RadioBeam.User.Device
  alias RadioBeam.User.EventFilter
  alias RadioBeam.User.Keys
  alias RadioBeam.Room
  alias RadioBeam.Room.EventGraph.PaginationToken
  alias RadioBeam.Room.Timeline

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RadioBeamWeb.Schemas.Sync

  def sync(conn, _params) do
    %User{} = user = conn.assigns.user
    %Device{} = device = conn.assigns.device
    request = conn.assigns.request

    opts =
      Enum.reduce(request, [], fn
        {"since", since_token}, opts -> Keyword.put(opts, :since, since_token)
        {"timeout", timeout}, opts -> Keyword.put(opts, :timeout, timeout)
        {"full_state", full_state?}, opts -> Keyword.put(opts, :full_state?, full_state?)
        {"filter", %{} = filter}, opts -> Keyword.put(opts, :filter, EventFilter.new(filter))
        {"filter", filter_id}, opts -> Keyword.put(opts, :filter, get_user_event_filter(user, filter_id))
        _, opts -> opts
      end)

    maybe_since_token = Keyword.get(opts, :since)

    response =
      user.id
      |> Room.all_where_has_membership()
      |> Timeline.sync(user.id, device.id, opts)
      |> put_account_data(user)
      |> put_to_device_messages(user.id, device.id, maybe_since_token)
      |> put_device_key_changes(user, maybe_since_token)
      |> put_device_otk_usages(device)

    json(conn, response)
  end

  def get_messages(conn, %{"room_id" => room_id}) do
    %User{} = user = conn.assigns.user
    %Device{} = device = conn.assigns.device
    request = conn.assigns.request

    dir = Map.fetch!(request, "dir")

    from_and_dir =
      case Map.fetch(request, "from") do
        {:ok, %PaginationToken{} = from} -> {from, dir}
        :error -> if dir == :forward, do: :root, else: :tip
      end

    to = Map.get(request, "to", :limit)

    opts =
      request
      |> Map.take(["filter", "limit"])
      |> Enum.reduce([], fn
        {"filter", %{} = filter}, opts -> Keyword.put(opts, :filter, EventFilter.new(filter))
        {"filter", filter_id}, opts -> Keyword.put(opts, :filter, get_user_event_filter(user, filter_id))
        {"limit", limit}, opts -> Keyword.put(opts, :limit, limit)
      end)

    case Timeline.get_messages(room_id, user.id, device.id, from_and_dir, to, opts) do
      {:ok, response} -> json(conn, response)
      {:error, error} -> handle_common_error(conn, error)
    end
  end

  defp put_account_data(sync, user) do
    sync
    |> Map.merge(%{account_data: Map.get(user.account_data, :global, %{})})
    |> update_in(
      [:rooms, :join],
      &Map.new(&1, fn {room_id, room_sync} ->
        {room_id, Map.put(room_sync, :account_data, Map.get(user.account_data, room_id, %{}))}
      end)
    )
  end

  defp put_to_device_messages(response, user_id, device_id, mark_as_read) do
    case Device.Message.take_unsent(user_id, device_id, response.next_batch, mark_as_read) do
      {:ok, unsent_messages} ->
        RadioBeam.put_nested(response, [:to_device, :events], unsent_messages)

      :none ->
        response

      error ->
        Logger.error("error when fetching unsent device messages: #{inspect(error)}")
        response
    end
  end

  defp put_device_key_changes(response, _user, nil), do: response

  defp put_device_key_changes(response, user, since) do
    changed_map =
      user
      |> Keys.all_changed_since(since)
      |> Map.update!(:changed, &MapSet.to_list/1)
      |> Map.update!(:left, &MapSet.to_list/1)

    Map.put(response, :device_lists, changed_map)
  end

  defp put_device_otk_usages(response, %Device{} = device) do
    response =
      case Device.OneTimeKeyRing.one_time_key_counts(device.one_time_key_ring) do
        counts when map_size(counts) > 0 -> Map.put(response, :device_one_time_keys_count, counts)
        _else -> response
      end

    unused_fallback_algos =
      Map.keys(device.one_time_key_ring.fallback_keys) -- MapSet.to_list(device.one_time_key_ring.used_fallback_algos)

    Map.put(response, :device_unused_fallback_key_types, unused_fallback_algos)
  end

  defp get_user_event_filter(%User{} = user, filter_id) do
    case User.get_event_filter(user, filter_id) do
      {:ok, filter} -> filter
      {:error, :not_found} -> EventFilter.new(%{})
    end
  end
end
