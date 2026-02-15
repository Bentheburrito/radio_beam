defmodule RadioBeamWeb.SyncController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2]

  require Logger

  alias RadioBeam.Room.Timeline
  alias RadioBeam.Sync

  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RadioBeamWeb.Schemas.Sync

  def sync(conn, _params) do
    user_id = conn.assigns.user_id
    device_id = conn.assigns.device_id
    request = conn.assigns.request

    opts =
      Enum.reduce(request, [], fn
        {"since", since_token}, opts -> Keyword.put(opts, :since, since_token)
        {"timeout", timeout}, opts -> Keyword.put(opts, :timeout, timeout)
        {"full_state", full_state?}, opts -> Keyword.put(opts, :full_state?, full_state?)
        {"filter", filter}, opts -> Keyword.put(opts, :filter, filter)
        _, opts -> opts
      end)

    sync_result = Sync.perform_v2(user_id, device_id, opts)

    json(conn, sync_result)
  end

  def get_messages(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.user_id
    device_id = conn.assigns.device_id
    request = conn.assigns.request

    dir = Map.fetch!(request, "dir")

    from_and_dir =
      case Map.fetch(request, "from") do
        {:ok, from} -> {from, dir}
        :error -> if dir == :forward, do: :root, else: :tip
      end

    opts =
      request
      |> Map.take(["filter", "limit"])
      |> Enum.reduce([to: :limit], fn
        {"filter", filter}, opts -> Keyword.put(opts, :filter, %{"room" => %{"timeline" => filter}})
        {"limit", limit}, opts -> Keyword.put(opts, :limit, limit)
      end)

    case Timeline.get_messages(room_id, user_id, device_id, from_and_dir, opts) do
      {:ok, response} -> json(conn, response)
      {:error, :not_found} -> handle_common_error(conn, :unauthorized)
      {:error, error} -> handle_common_error(conn, error)
    end
  end
end
