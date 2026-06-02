defmodule RadioBeam.Room.Upgrades do
  @moduledoc """
  Upgrade (or downgrade) rooms.
  """

  alias RadioBeam.Room.Core
  alias RadioBeam.Room.Database
  alias RadioBeam.Room.View

  require Logger

  @state_types_to_transfer ~w|server_acl encryption name avatar topic guest_access history_visibility join_rules power_levels|
  @state_keys_to_transfer Enum.map(@state_types_to_transfer, &{"m.room.#{&1}", ""})
  def perform(room, user_id, new_version, addl_creator_ids, deps) do
    with :ok <- ensure_can_send_tombstone(room, user_id),
         {:ok, new_room_id} <- create_upgraded_room(room, new_version, user_id, addl_creator_ids, deps),
         :ok <- Database.rebind_aliases(room.id, new_room_id),
         {:ok, tombstone_id} <- put_tombstone_event(room.id, user_id, new_room_id, new_version, deps) do
      Logger.info("upgraded #{room.id} -> #{new_room_id} (v#{new_version}). Tombstone event ID: #{tombstone_id}")

      # updating the power levels of the old room is not integral to the
      # upgrade process, so we do it as a side effect without checking the
      # result.
      try_seal_old_room(room.id, user_id, deps)

      {:ok, new_room_id}
    end
  end

  defp ensure_can_send_tombstone(room, user_id) do
    if Core.can_send_event?(room, user_id, "m.room.tombstone", "") do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp create_upgraded_room(old_room, new_version, creator_id, addl_creator_ids, deps) do
    create_event_content = %{"predecessor" => %{"room_id" => old_room.id}, "additional_creators" => addl_creator_ids}

    event_id_stream =
      old_room
      |> Core.get_state_mapping()
      |> Map.take(@state_keys_to_transfer)
      |> Stream.map(&elem(&1, 1))

    state_events_to_transfer =
      old_room.id
      |> View.get_events!(creator_id, event_id_stream, false)
      |> Stream.map(&map_power_levels_content(new_version, &1, [creator_id | addl_creator_ids]))
      |> Enum.map(&%{"content" => &1.content, "type" => &1.type, "state_key" => &1.state_key})

    deps.create_room.(creator_id,
      content: create_event_content,
      addl_state_events: state_events_to_transfer,
      version: new_version
    )
  end

  defp map_power_levels_content(version, %{type: "m.room.power_levels"} = event, [creator_id | _addl_creators])
       when version in ~w|1 2 3 4 5 6 7 8 9 10 11| do
    event.content["users"][creator_id]
    |> put_in(100)
    |> cap_tombstone_pl()
  end

  defp map_power_levels_content("12", %{type: "m.room.power_levels"} = event, creator_ids),
    do: update_in(event.content["users"], &Map.drop(&1, creator_ids))

  defp map_power_levels_content(_version, event, _creator_ids), do: event

  defp cap_tombstone_pl(%{content: %{"events" => %{"m.room.tombstone" => _}}} = event),
    do: update_in(event.content["events"]["m.room.tombstone"], &min(&1, 100))

  defp cap_tombstone_pl(event), do: event

  defp put_tombstone_event(room_id, user_id, new_room_id, new_version, deps) do
    deps.put_state.(room_id, user_id, "m.room.tombstone", "", %{
      "body" =>
        "This room has been upgraded to version #{new_version}. Please discontinue use of this room and continue the conversation at #{new_room_id}.",
      "replacement_room" => new_room_id
    })
  end

  defp try_seal_old_room(old_room_id, user_id, deps) do
    with {:ok, event} <- deps.get_state.(old_room_id, user_id, "m.room.power_levels", "") do
      # "If possible, the power levels in the old room should also be modified
      # to prevent sending of events and inviting new users. For example,
      # setting events_default and invite to the greater of 50 and
      # users_default + 1."
      new_send_event_power_level = max(50, Map.get(event.content, "users_default", 0) + 1)

      new_content =
        event.content
        |> Map.put("invite", new_send_event_power_level)
        |> Map.put("events_default", new_send_event_power_level)

      deps.put_state.(old_room_id, user_id, "m.room.power_levels", "", new_content)
    end
  end
end
