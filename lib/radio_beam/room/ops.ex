defmodule RadioBeam.Room.Ops do
  @moduledoc """
  ❗This is a private module intended to only be used by `Room` GenServers. It 
  provides an API for common operations (ops) to take against a room, often 
  requiring atomic DB actions. Use functions in the `Room` module instead.
  """

  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.RoomAlias

  require Logger

  @doc """
  Attempts to apply the given events to a room. Events are run through the 
  room's auth checks, and the whole list of events is rejected if one of them
  fails the checks.
  """
  @spec put_events(Room.t(), [map()]) :: {:ok, Room.t()} | {:error, any()}
  def put_events(%Room{} = room, events) do
    events
    |> Enum.reduce_while({room, []}, fn event, {%Room{} = room, pdus} ->
      auth_events = select_auth_events(event, room.state)

      with true <- authorized?(room, event, auth_events),
           {:ok, %Room{} = room, %PDU{} = pdu} <- update_room(room, event, auth_events) do
        {:cont, {room, [pdu | pdus]}}
      else
        false ->
          Logger.info("Rejecting unauthorized event:\n#{inspect(event)}")
          {:halt, {:error, :unauthorized}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {%Room{} = room, pdus} ->
        persist_put_events(room, pdus)

      error ->
        error
    end
  end

  defp persist_put_events(%Room{} = room, pdus) do
    Memento.transaction(fn ->
      addl_actions =
        for %PDU{} = pdu <- pdus, do: pdu |> Memento.Query.write() |> get_pdu_followup_actions()

      room = Memento.Query.write(room)

      addl_actions
      |> List.flatten()
      |> Stream.filter(&is_function(&1))
      |> Enum.find_value(room, fn action ->
        case action.() do
          {:error, error} -> Memento.Transaction.abort(error)
          _result -> false
        end
      end)
    end)
  end

  defp get_pdu_followup_actions(%PDU{type: "m.room.canonical_alias"} = pdu) do
    for room_alias <- [pdu.content["alias"] | Map.get(pdu.content, "alt_aliases", [])], not is_nil(room_alias) do
      fn -> RoomAlias.put(room_alias, pdu.room_id) end
    end
  end

  # TOIMPL: add room to published room list if visibility option was set to :public
  defp get_pdu_followup_actions(%PDU{}), do: nil

  defp select_auth_events(event, state) do
    keys = [{"m.room.create", ""}, {"m.room.power_levels", ""}]
    keys = if event["sender"] != event["state_key"], do: [{"m.room.member", event["sender"]} | keys], else: keys

    keys =
      if event["type"] == "m.room.member" do
        # TODO: check if room version actually supports restricted rooms
        keys =
          if sk = Map.get(event["content"], "join_authorised_via_users_server"),
            do: [{"m.room.member", sk} | keys],
            else: keys

        cond do
          match?(%{"membership" => "invite", "third_party_invite" => _}, event["content"]) ->
            [
              {"m.room.member", event["state_key"]},
              {"m.room.join_rules", ""},
              {"m.room.third_party_invite", get_in(event, ~w[content third_party_invite signed token])} | keys
            ]

          event["content"]["membership"] in ~w[join invite] ->
            [{"m.room.member", event["state_key"]}, {"m.room.join_rules", ""} | keys]

          :else ->
            [{"m.room.member", event["state_key"]} | keys]
        end
      else
        keys
      end

    for key <- keys, is_map_key(state, key), do: state[key]
  end

  defp authorized?(%Room{} = room, event, auth_events) do
    RoomVersion.authorized?(room.version, event, room.state, auth_events)
  end

  defp update_room(room, event, auth_events) do
    pdu_attrs =
      event
      |> Map.put("auth_events", Enum.map(auth_events, & &1["event_id"]))
      # ??? why are there no docs on depth besides the PDU desc
      |> Map.put("depth", room.depth + 1)
      |> Map.put("prev_events", room.latest_event_ids)
      |> Map.put("prev_state", room.state)

    with {:ok, pdu} = PDU.new(pdu_attrs, room.version) do
      room =
        room
        |> Map.update!(:depth, &(&1 + 1))
        |> Map.replace!(:latest_event_ids, [pdu.event_id])
        |> update_room_state(Map.put(event, "event_id", pdu.event_id))

      {:ok, room, pdu}
    end
  end

  defp update_room_state(room, event) do
    if is_map_key(event, "state_key") do
      %Room{room | state: Map.put(room.state, {event["type"], event["state_key"]}, event)}
    else
      room
    end
  end
end
