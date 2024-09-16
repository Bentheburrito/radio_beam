defmodule RadioBeamWeb.SyncController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2]

  require Logger

  alias RadioBeam.Device
  alias RadioBeam.User
  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline
  alias RadioBeam.Room.Timeline.Filter

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
        {"filter", filter}, opts -> Keyword.put(opts, :filter, Filter.parse(filter))
        _, opts -> opts
      end)

    response =
      user.id
      |> Room.all_where_has_membership()
      |> Timeline.sync(user.id, device.id, opts)
      |> put_account_data(user)
      |> put_to_device_messages(user.id, device.id, Keyword.get(opts, :since))

    json(conn, response)
  end

  def get_messages(conn, %{"room_id" => room_id}) do
    %User{} = user = conn.assigns.user
    %Device{} = device = conn.assigns.device
    request = conn.assigns.request

    dir = Map.fetch!(request, "dir")

    from = Map.get(request, "from", (dir == :forward && :first) || :last)
    to = Map.get(request, "to", :limit)

    opts =
      request
      |> Map.take(["filter", "limit"])
      |> Enum.reduce([], fn
        {"filter", filter}, opts -> Keyword.put(opts, :filter, Filter.parse(filter))
        {"limit", limit}, opts -> Keyword.put(opts, :limit, limit)
      end)

    case Timeline.get_messages(room_id, user.id, device.id, dir, from, to, opts) do
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
        Map.put(response, :to_device, Enum.map(unsent_messages, & &1.content))

      :none ->
        response

      error ->
        Logger.error("error when fetching unsent device messages: #{inspect(error)}")
        response
    end
  end
end
