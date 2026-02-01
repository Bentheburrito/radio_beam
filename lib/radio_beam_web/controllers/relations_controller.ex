defmodule RadioBeamWeb.RelationsController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2]

  alias RadioBeam.Room
  alias RadioBeamWeb.Schemas.Relations, as: RelationsSchema

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RelationsSchema

  def get_children(conn, %{"event_id" => event_id, "room_id" => room_id} = params) do
    user_id = conn.assigns.user_id
    %{"dir" => order, "recurse" => recurse?} = _request = conn.assigns.request

    opts = [
      event_type: Map.get(params, "event_type"),
      order: order,
      recurse?: recurse?,
      rel_type: Map.get(params, "rel_type")
    ]

    case Room.get_children(room_id, user_id, event_id, opts) do
      {:ok, child_events, recurse_depth} ->
        # TOIMPL: this endpoint can take a from/to token returned from /messages
        # and /sync (so a NextBatch). Room.get_children does not currently
        # support this (nor a `limit`), so just returning all children for now -
        # need to come back to do this properly

        json(conn, %{chunk: child_events, recursion_depth: recurse_depth})

      {:error, _error} ->
        handle_common_error(conn, :not_found)
    end
  end
end
