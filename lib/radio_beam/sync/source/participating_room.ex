defmodule RadioBeam.Sync.Source.ParticipatingRoom do
  @moduledoc """
  Returns timeline and other information associated with a room the user is a
  member of.
  """
  @behaviour RadioBeam.Sync.Source

  alias RadioBeam.PubSub
  alias RadioBeam.Room.Database
  alias RadioBeam.Room.EphemeralState
  alias RadioBeam.Room.Sync.Core
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache
  alias RadioBeam.Room.View
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Sync.Source

  require Logger

  @impl Source
  def top_level_path(_room_id, timeline), do: ["rooms", "join", timeline.room_id]

  @impl Source
  def inputs, do: ~w|account_data user_id device_id ignored_user_ids event_filter known_memberships full_state?|a

  @impl Source
  def run(inputs, room_id, sink_pid) do
    room_id
    |> PubSub.all_room_events()
    |> PubSub.subscribe()

    inputs =
      put_in(inputs, [:functions], %{
        event_stream: &View.timeline_event_stream!(&1, inputs.user_id, :tip),
        get_events_for_user: &View.get_events!(&1, inputs.user_id, &2),
        typing_user_ids: &RadioBeam.Room.EphemeralState.all_typing/1
      })

    inputs
    |> perform(room_id)
    |> wait_if_empty(inputs, room_id, sink_pid)
    |> side_effects(inputs, room_id)
  end

  defp perform(inputs, room_id) do
    with {:ok, room} <- Database.fetch_room(room_id), do: Core.perform(inputs, room)
  end

  defp wait_if_empty(room_sync_result, inputs, room_id, sink_pid) do
    if room_sync_result == :no_update or
         (Enum.empty?(room_sync_result.timeline_events) and Enum.empty?(room_sync_result.state_events)) do
      Source.notify_waiting(sink_pid, room_id)

      Enum.find_value(new_room_events_stream(), fn
        {:room_event, ^room_id, %Event{} = _event} ->
          room_sync_result = perform(inputs, room_id)

          if room_sync_result == :no_update or Enum.empty?(room_sync_result.timeline_events) do
            nil
          else
            {:ok, room_sync_result, maybe_next_batch(inputs, room_sync_result)}
          end

        {:room_ephemeral_state_update, ^room_id, %EphemeralState{} = state} ->
          room_sync_result =
            JoinedRoomResult.new_ephemeral(room_id, inputs.account_data, "join", EphemeralState.Core.all_typing(state))

          {:ok, room_sync_result, maybe_next_batch(inputs, room_sync_result)}

        :noop ->
          nil
      end)
    else
      {:ok, room_sync_result, maybe_next_batch(inputs, room_sync_result)}
    end
  end

  defp side_effects({:ok, room_sync_result, next_batch}, inputs, room_id) do
    sender_ids = room_sync_result.sender_ids |> MapSet.delete(inputs.user_id) |> MapSet.to_list()
    LazyLoadMembersCache.put(inputs.device_id, room_id, sender_ids)

    {:ok, room_sync_result, next_batch}
  end

  defp side_effects({:no_update, _} = result, _inputs, _room_id), do: result

  defp maybe_next_batch(inputs, room_sync_result) do
    case room_sync_result do
      %JoinedRoomResult{latest_event_id: :use_latest} -> Map.get(inputs, :last_batch)
      %JoinedRoomResult{latest_event_id: event_id} -> event_id
    end
  end

  defp new_room_events_stream do
    Stream.repeatedly(fn ->
      receive do
        {:room_event, "!" <> _, %Event{}} = message -> message
        {:room_ephemeral_state_update, "!" <> _, %EphemeralState{}} = message -> message
        _ -> :noop
      end
    end)
  end
end
