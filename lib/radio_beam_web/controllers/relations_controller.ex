defmodule RadioBeamWeb.RelationsController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2]

  alias RadioBeam.Room
  alias RadioBeam.Sync
  alias RadioBeamWeb.Schemas.Relations, as: RelationsSchema

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema, mod: RelationsSchema

  def get_children(conn, %{"event_id" => event_id, "room_id" => room_id} = params) do
    user_id = conn.assigns.user_id
    %{"dir" => order, "recurse" => recurse?, "limit" => limit} = conn.assigns.request

    opts =
      [
        event_type: Map.get(params, "event_type"),
        order: order,
        recurse?: recurse?,
        rel_type: Map.get(params, "rel_type")
      ]
      |> maybe_put_batch_opt(:from, room_id, Map.get(conn.assigns.request, "from"))
      |> maybe_put_batch_opt(:to, room_id, Map.get(conn.assigns.request, "to"))

    case Room.get_children(room_id, user_id, event_id, limit, opts) do
      {:ok, child_events, recurse_depth} ->
        # TOIMPL: this endpoint can take a from/to token returned from /messages
        # and /sync (so a NextBatch). Room.get_children does not currently
        # support this (nor a `limit`), so just returning all children for now -
        # need to come back to do this properly

        response =
          %{chunk: child_events, recursion_depth: recurse_depth}
          |> maybe_put_batch_response(order, Map.get(conn.assigns.request, "from"))

        json(conn, response)

      {:error, _error} ->
        handle_common_error(conn, :not_found)
    end
  end

  defp maybe_put_batch_opt(opts, _opt_key, _room_id, nil), do: opts

  defp maybe_put_batch_opt(opts, opt_key, room_id, batch_token) do
    case Sync.parse_event_id_at(batch_token, room_id) do
      {:ok, event_id} -> Keyword.put(opts, opt_key, event_id)
      {:error, :not_found} -> opts
    end
  end

  defp maybe_put_batch_response(%{chunk: [first_event | _] = events} = response, :chronological, _from) do
    last_event = List.last(events)

    response
    |> Map.put(:next_batch, Sync.new_batch_token_for(first_event.room_id, first_event.id))
    |> Map.put(:prev_batch, Sync.new_batch_token_for(last_event.room_id, last_event.id))
  end

  defp maybe_put_batch_response(%{chunk: [last_event | _] = events} = response, :reverse_chronological, _from) do
    first_event = List.last(events)

    response
    |> Map.put(:next_batch, Sync.new_batch_token_for(first_event.room_id, first_event.id))
    |> Map.put(:prev_batch, Sync.new_batch_token_for(last_event.room_id, last_event.id))
  end

  defp maybe_put_batch_response(%{chunk: []} = response, _order, nil), do: response

  defp maybe_put_batch_response(%{chunk: []} = response, _order, from_batch_token) do
    Map.put(response, :prev_batch, from_batch_token)
  end
end
