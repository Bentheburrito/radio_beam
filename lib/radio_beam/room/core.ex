defmodule RadioBeam.Room.Core do
  @moduledoc """
  ❗This is a private module intended to only be used by `Room` GenServers. It 
  serves as the functional core for a room, housing business logic for 
  """

  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.PDU
  alias RadioBeam.Room

  @doc """
  Attempts to apply the given event to a room. If it is a valid event that
  satisfies auth checks, returns `{:ok, room, pdu}`, and `{:error, error}`
  otherwise.
  """
  @spec put_event(Room.t(), map()) :: {:ok, Room.t(), PDU.t()} | {:error, any()}
  def put_event(%Room{} = room, event) do
    auth_events = select_auth_events(event, room.state)

    if authorized?(room, event, auth_events) do
      update_room(room, event, auth_events)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Similar to `put_event/2`, but takes a list of events. The whole list of
  events is rejected if one of them fails auth checks.
  """
  @spec put_events(Room.t(), [map()]) :: {:ok, Room.t(), [PDU.t()]} | {:error, any()}
  def put_events(%Room{} = room, events) do
    Enum.reduce_while(events, {:ok, room, []}, fn event, {:ok, %Room{} = room, pdus} ->
      case put_event(room, event) do
        {:ok, room, pdu} -> {:cont, {:ok, room, [pdu | pdus]}}
        error -> {:halt, error}
      end
    end)
  end

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
      |> Map.put("depth", room.depth)
      |> Map.put("prev_events", room.latest_event_ids)
      |> Map.put("prev_state", room.state)

    with {:ok, pdu} <- PDU.new(pdu_attrs, room.version) do
      room =
        room
        |> Map.update!(:depth, &(&1 + 1))
        |> Map.replace!(:latest_event_ids, [pdu.event_id])
        |> update_room_state(PDU.to_event(pdu, room.version, :strings))

      {:ok, room, pdu}
    end
  end

  def update_room_state(%Room{} = room, event) do
    if is_map_key(event, "state_key") do
      %Room{room | state: Map.put(room.state, {event["type"], event["state_key"]}, event)}
    else
      room
    end
  end
end
