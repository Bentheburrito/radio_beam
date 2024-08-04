defmodule RadioBeamWeb.SyncController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2]

  require Logger

  alias RadioBeam.User
  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RadioBeamWeb.Schemas.Sync

  def sync(conn, _params) do
    %User{} = user = conn.assigns.user
    request = conn.assigns.request

    opts =
      Enum.reduce(request, [], fn
        {"since", since_token}, opts -> Keyword.put(opts, :since, since_token)
        {"timeout", timeout}, opts -> Keyword.put(opts, :timeout, timeout)
        {"full_state", full_state?}, opts -> Keyword.put(opts, :full_state?, full_state?)
        {"filter", filter}, opts -> Keyword.put(opts, :filter, filter)
        _, opts -> opts
      end)

    response =
      user.id
      |> Room.all_where_has_membership()
      |> Timeline.sync(user.id, opts)

    json(conn, response)
  end

  def get_messages(conn, %{"room_id" => room_id}) do
    %User{} = user = conn.assigns.user
    request = conn.assigns.request

    dir = Map.fetch!(request, "dir")

    from = Map.get(request, "from", (dir == :forward && :first) || :last)
    to = Map.get(request, "to", :limit)

    opts =
      request
      |> Map.take(["filter", "limit"])
      |> Enum.reduce([], fn
        {"filter", filter}, opts -> Keyword.put(opts, :filter, filter)
        {"limit", limit}, opts -> Keyword.put(opts, :limit, limit)
      end)

    case Timeline.get_messages(room_id, user.id, dir, from, to, opts) do
      {:ok, response} -> json(conn, response)
      {:error, error} -> handle_common_error(conn, error)
    end
  end
end
