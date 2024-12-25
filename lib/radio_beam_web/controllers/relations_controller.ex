defmodule RadioBeamWeb.RelationsController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2]

  alias RadioBeam.Room.Timeline
  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeamWeb.Schemas.Relations, as: RelationsSchema

  require Logger

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RelationsSchema

  def get_children(conn, %{"event_id" => event_id, "room_id" => room_id}) do
    %User{} = user = conn.assigns.user
    %{"dir" => dir, "recurse" => recurse} = _request = conn.assigns.request

    recurse_level =
      if recurse, do: Application.fetch_env!(:radio_beam, :max_event_recurse), else: 1

    # TOIMPL: this endpoint can take a from/to token returned from /messages
    # and /sync (so a PaginationToken). PDU.get_children does not currently
    # support this (nor a `limit`), so just returning all children for now -
    # need to come back to do this properly
    with {:ok, %PDU{} = pdu} <- Room.get_event(room_id, user.id, event_id),
         {:ok, children} <- PDU.get_children(pdu, recurse_level) do
      # we can't use Timeline.filter_authz here because it assumes we're
      # filtering against a contiguous slice of the room history, (and thus
      # certain assumptions used to update state/membership don't hold up).
      children =
        if dir == :forward do
          children |> Stream.filter(&Timeline.authz_to_view?(&1, user.id)) |> Enum.reverse()
        else
          Enum.filter(children, &Timeline.authz_to_view?(&1, user.id))
        end

      json(conn, %{chunk: children, recursion_depth: recurse_level})
    else
      {:error, _error} -> handle_common_error(conn, :not_found)
    end
  end
end
