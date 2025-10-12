defmodule RadioBeamWeb.RelationsController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2]

  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeamWeb.Schemas.Relations, as: RelationsSchema

  require Logger

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RelationsSchema

  def get_children(conn, %{"event_id" => event_id, "room_id" => room_id} = params) do
    %User{} = user = conn.assigns.user
    %{"dir" => order, "recurse" => recurse?} = _request = conn.assigns.request

    opts = [
      event_type: Map.get(params, "event_type"),
      order: order,
      recurse?: recurse?,
      rel_type: Map.get(params, "rel_type")
    ]

    with {:ok, child_events, recurse_depth} <- Room.get_children(room_id, user.id, event_id, opts) do
      # TOIMPL: this endpoint can take a from/to token returned from /messages
      # and /sync (so a PaginationToken). EventGraph.get_children does not currently
      # support this (nor a `limit`), so just returning all children for now -
      # need to come back to do this properly

      json(conn, %{chunk: child_events, recursion_depth: recurse_depth})
    else
      {:error, _error} -> handle_common_error(conn, :not_found)
    end
  end
end
