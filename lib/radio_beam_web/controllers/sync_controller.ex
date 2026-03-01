defmodule RadioBeamWeb.SyncController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [handle_common_error: 2, json_error: 4]

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
    from = parse_from_event_id(Map.fetch(request, "from"), room_id, dir)

    opts =
      request
      |> Map.take(["filter", "limit"])
      |> Enum.reduce([to: :limit], fn
        {"filter", filter}, opts -> Keyword.put(opts, :filter, %{"room" => %{"timeline" => filter}})
        {"limit", limit}, opts -> Keyword.put(opts, :limit, limit)
      end)

    case Timeline.get_messages(room_id, user_id, device_id, from, opts) do
      {:ok, timeline_events, maybe_next_event_id, state_event_stream} ->
        json(
          conn,
          %{chunk: timeline_events, state: Enum.to_list(state_event_stream)}
          |> put_start(room_id)
          |> maybe_put_end(maybe_next_event_id, room_id)
        )

      {:error, :not_found} ->
        handle_common_error(conn, :unauthorized)

      {:error, error} ->
        handle_common_error(conn, error)
    end
  end

  defp parse_from_event_id({:ok, from}, room_id, dir) do
    case Sync.parse_event_id_at(from, room_id) do
      {:ok, event_id} -> {event_id, dir}
      {:error, :not_found} -> if dir == :forward, do: :root, else: :tip
    end
  end

  defp parse_from_event_id(:error, _room_id, dir) do
    if dir == :forward, do: :root, else: :tip
  end

  defp maybe_put_end(response, :no_more_events, _room_id), do: response

  defp maybe_put_end(response, "$" <> _ = end_event_id, room_id),
    do: Map.put(response, :end, Sync.new_batch_token_for(room_id, end_event_id))

  defp put_start(%{chunk: [%{id: "$" <> _ = start_event_id} | _]} = response, room_id) do
    Map.put(response, :start, Sync.new_batch_token_for(room_id, start_event_id))
  end

  defp put_start(%{} = response, _room_id), do: Map.put(response, :start, Sync.new_batch_token())

  def get_event_context(conn, %{"room_id" => room_id, "event_id" => event_id}) do
    user_id = conn.assigns.user_id
    device_id = conn.assigns.device_id

    opts =
      conn.assigns.request
      |> Map.take(["filter", "limit"])
      |> Enum.reduce([to: :limit], fn
        {"filter", filter}, opts -> Keyword.put(opts, :filter, %{"room" => %{"timeline" => filter}})
        {"limit", limit}, opts -> Keyword.put(opts, :limit, limit)
      end)

    case Timeline.get_context(room_id, user_id, device_id, event_id, opts) do
      {:ok, %{id: ^event_id} = event, events_before, start_event_id, events_after, end_event_id} ->
        response =
          maybe_put_start(
            %{
              end: Sync.new_batch_token_for(room_id, end_event_id),
              event: event,
              events_after: events_after,
              events_before: events_before
              # TOIMPL: return the state of the room at the latest event
            },
            start_event_id,
            room_id
          )

        json(conn, response)

      {:error, error} when error in ~w|not_found unauthorized|a ->
        json_error(conn, 404, :not_found, "That room or event was not found")
    end
  end

  defp maybe_put_start(response, :no_more_events, _room_id), do: response
  defp maybe_put_start(response, eid, room_id), do: Map.put(response, :start, Sync.new_batch_token_for(room_id, eid))
end
