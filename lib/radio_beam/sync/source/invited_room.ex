defmodule RadioBeam.Sync.Source.InvitedRoom do
  @moduledoc """
  Returns a room ID the user gets invited to. Does not return invites that have
  been sent in a previous sync.
  """
  @behaviour RadioBeam.Sync.Source

  alias RadioBeam.PubSub
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Sync.Source

  @impl Source
  def top_level_path(_key, invited_room_result), do: ["rooms", "invite", invited_room_result.room_id]

  @impl Source
  def inputs, do: [:user_id, :ignored_user_ids]

  @impl Source
  def init(inputs, _key) do
    inputs.user_id |> PubSub.invite_events() |> PubSub.subscribe()
  end

  @mod inspect(__MODULE__)
  @impl Source
  def run(inputs, @mod = key, sink_pid) do
    user_id = inputs.user_id

    Source.notify_waiting(sink_pid, key)

    wait_for_invite_events(inputs, user_id)
  end

  def run(%{last_batch: "sent"}, _key, _sink_pid), do: {:no_update, "sent"}

  def run(inputs, "!" <> _ = room_id, _sink_pid) do
    case RadioBeam.Room.fetch_state_pdu_at(room_id, :current_state, "m.room.member", inputs.user_id, true) do
      {:ok, %PDU{event: %{sender: sender_id, content: %{"membership" => "invite"}}}} ->
        if sender_id in inputs.ignored_user_ids do
          {:no_update, nil}
        else
          invite_state_events = Room.get_invite_state_events(room_id, inputs.user_id)
          {:ok, InvitedRoomResult.new!(room_id, invite_state_events), "sent"}
        end

      _ ->
        {:no_update, nil}
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
