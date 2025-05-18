defmodule RadioBeamWeb.RelationsController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2]

  alias RadioBeam.Room.Timeline
  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.User
  alias RadioBeamWeb.Schemas.Relations, as: RelationsSchema

  require Logger

  plug RadioBeamWeb.Plugs.Authenticate
  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RelationsSchema

  def get_children(conn, %{"event_id" => event_id, "room_id" => room_id} = params) do
    %User{} = user = conn.assigns.user
    %{"dir" => dir, "recurse" => recurse} = _request = conn.assigns.request

    recurse_level =
      if recurse, do: Application.fetch_env!(:radio_beam, :max_event_recurse), else: 1

    # TOIMPL: this endpoint can take a from/to token returned from /messages
    # and /sync (so a PaginationToken). EventGraph.get_children does not currently
    # support this (nor a `limit`), so just returning all children for now -
    # need to come back to do this properly
    with {:ok, %PDU{} = pdu} <- Room.get_event(room_id, user.id, event_id, _bundle_aggregates? = false),
         {:ok, children} <- EventGraph.get_children(pdu, recurse_level) do
      rel_type = Map.get(params, "rel_type")
      event_type = Map.get(params, "event_type")

      children =
        if dir == :forward do
          children |> filter(user.id, rel_type, event_type) |> Enum.reverse()
        else
          children |> filter(user.id, rel_type, event_type) |> Enum.to_list()
        end

      json(conn, %{chunk: children, recursion_depth: recurse_level})
    else
      {:error, _error} -> handle_common_error(conn, :not_found)
    end
  end

  defp filter(children, user_id, rel_type, event_type) do
    # we can't use Timeline.filter_authz here because it assumes we're
    # filtering against a contiguous slice of the room history, (and thus
    # certain assumptions used to update state/membership don't hold up).
    Stream.filter(children, fn pdu ->
      Timeline.authz_to_view?(pdu, user_id) and filter_rel_type(pdu, rel_type) and filter_event_type(pdu, event_type)
    end)
  end

  defp filter_rel_type(_pdu, nil), do: true
  defp filter_rel_type(%PDU{content: %{"m.relates_to" => %{"rel_type" => rel_type}}}, rel_type), do: true
  defp filter_rel_type(_pdu, _rel_type), do: false

  defp filter_event_type(_pdu, nil), do: true
  defp filter_event_type(%PDU{type: event_type}, event_type), do: true
  defp filter_event_type(_pdu, _event_type), do: false
end
