defmodule RadioBeam.Sync.Source.InvitedRoom do
  @moduledoc """
  Returns a room ID the user gets invited to. Does not return invites that have
  been sent in a previous sync.
  """
  @behaviour RadioBeam.Sync.Source

  alias RadioBeam.PubSub
  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Sync.Source

  @impl Source
  def top_level_path(_key, invited_room_result), do: ["rooms", "invite", invited_room_result.room_id]

  @impl Source
  def inputs, do: [:user_id, :ignored_user_ids]

  @mod inspect(__MODULE__)
  @impl Source
  def run(inputs, @mod = key, sink_pid) do
    user_id = inputs.user_id

    user_id
    |> PubSub.invite_events()
    |> PubSub.subscribe()

    Source.notify_waiting(sink_pid, key)

    wait_for_invite_events(inputs, user_id)
  end

  def run(%{last_batch: "sent"}, _key, _sink_pid), do: {:no_update, "sent"}

  def run(inputs, "!" <> _ = room_id, _sink_pid) do
    with {:ok, room} <- RadioBeam.Room.Database.fetch_room(room_id) do
      case RadioBeam.Room.State.fetch(room.state, "m.room.member", inputs.user_id) do
        {:ok, %{event: %{sender: sender_id, content: %{"membership" => "invite"}}}} ->
          if sender_id in inputs.ignored_user_ids do
            {:no_update, nil}
          else
            {:ok, InvitedRoomResult.new!(room, inputs.user_id), "sent"}
          end

        {:error, :not_found} ->
          {:no_update, nil}
      end
    end
  end

  defp wait_for_invite_events(inputs, user_id) do
    receive do
      {:room_invite, ^user_id, sender_id, room_id} ->
        if sender_id in inputs.ignored_user_ids do
          wait_for_invite_events(inputs, user_id)
        else
          with {:ok, invited_room_result, "sent"} <- run(inputs, room_id, nil) do
            {:ok, invited_room_result, {:next_batch, room_id, "sent"}}
          end
        end
    end
  end
end
