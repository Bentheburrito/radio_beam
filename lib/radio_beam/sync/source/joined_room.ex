defmodule RadioBeam.Sync.Source.JoinedRoom do
  @moduledoc """
  Returns a JoinedRoomResult for a room the user just joined.
  """
  @behaviour RadioBeam.Sync.Source

  alias RadioBeam.PubSub
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.Room.View
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Sync.Source

  @impl Source
  def top_level_path(_key, joined_room_result), do: ["rooms", "join", joined_room_result.room_id]

  @impl Source
  def inputs, do: ~w|account_data user_id event_filter known_memberships|a

  @impl Source
  def run(inputs, key, sink_pid) do
    user_id = inputs.user_id

    user_id
    |> PubSub.user_joined_room()
    |> PubSub.subscribe()

    Source.notify_waiting(sink_pid, key)

    receive do
      {:room_joined, %Event{type: "m.room.member", state_key: ^user_id} = membership_event} ->
        {:ok, room} = RadioBeam.Room.Database.fetch_room(membership_event.room_id)

        # TODO: known_memberships
        joined_room_result =
          JoinedRoomResult.new(
            room,
            user_id,
            inputs.account_data,
            [membership_event],
            &View.get_events!(&1, inputs.user_id, &2),
            "join",
            filter: inputs.event_filter,
            known_memberships: inputs.known_memberships
          )

        # put the event ID/next_batch value under the room ID, so the next sync
        # (ParticipatingRoom) knows where to pick up from
        {:ok, joined_room_result, {:next_batch, membership_event.room_id, membership_event.id}}
    end
  end
end
