defmodule RadioBeamWeb.SyncController do
  use RadioBeamWeb, :controller

  require Logger

  alias RadioBeam.User
  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline
  alias RadioBeamWeb.Schemas.Sync, as: SyncSchema

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, [get_schema: {SyncSchema, :sync, []}] when action == :sync

  def sync(conn, _params) do
    %User{} = user = conn.assigns.user
    request = conn.assigns.request

    opts =
      Enum.reduce(request, [], fn
        {"since", since_token}, opts -> Keyword.put(opts, :since, since_token)
        {"timeout", timeout}, opts -> Keyword.put(opts, :timeout, timeout)
        {"full_state", full_state?}, opts -> Keyword.put(opts, :full_state?, full_state?)
        _, opts -> opts
      end)

    response =
      user.id
      |> Room.all_where_has_membership()
      |> Timeline.sync(user.id, opts)

    json(conn, response)
  end
end
