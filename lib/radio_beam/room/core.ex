defmodule RadioBeam.Room.Core do
  @moduledoc """
  ❗This is a private module intended to only be used by `Room` GenServers. It 
  serves as the functional core for a room, housing business logic for 
  """

  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.Room

  @doc """
  TOIMPL: admins should be able to redact too

  > Any user with a power level greater than or equal to the m.room.redaction
  > event power level may send redaction events in the room. If the user’s
  > power level greater is also greater than or equal to the redact power level
  > of the room, the user may redact events sent by other users.
  > 
  > Server administrators may redact events sent by users on their server.
  > 
  > https://spec.matrix.org/latest/client-server-api/#put_matrixclientv3roomsroomidredacteventidtxnid
  """
  def authz_redact?(%Room{} = room, to_redact_sender, redaction_sender) do
    RoomVersion.has_power?(redaction_sender, "redact", false, room.state) or
      (RoomVersion.has_power?(redaction_sender, ~w|events m.room.redaction|, false, room.state) and
         to_redact_sender == redaction_sender)
  end

  def authorize(%Room{} = room, event) do
    auth_events = select_auth_events(event, room.state)

    if authorized?(room, event, auth_events) do
      {:ok, Map.put(event, "auth_events", Enum.map(auth_events, & &1["event_id"]))}
    else
      {:error, :unauthorized}
    end
  end

  def update_state(%Room{} = room, event) do
    if is_map_key(event, "state_key") do
      %Room{room | state: Map.put(room.state, {event["type"], event["state_key"]}, event)}
    else
      room
    end
  end

  def put_tip(%Room{} = room, latest_event_ids), do: Map.replace!(room, :latest_event_ids, latest_event_ids)

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
end
