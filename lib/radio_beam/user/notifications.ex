defmodule RadioBeam.User.Notifications do
  @moduledoc """
  Interface for user (push) notifications.
  """
  @behaviour RadioBeam.EventHandler

  alias RadioBeam.Room
  alias RadioBeam.Time
  alias RadioBeam.User
  alias RadioBeam.User.Database
  alias RadioBeam.User.Notification
  alias RadioBeam.User.Notifications.Core.Pusher
  alias RadioBeam.User.Notifications.Core.RuleSet

  defdelegate all_notifications(user_id), to: Database

  def unread_in_room_count(user_id, room_id) do
    user_id
    |> all_notifications()
    |> Enum.count(&(&1.room_id == room_id and &1.read == false))
  end

  @impl RadioBeam.EventHandler
  def handle_pdu(%{event: %{room_id: room_id, id: event_id, sender: sender_id}}, _) do
    with {:ok, joined_member_events} <- Room.get_members(room_id, sender_id, event_id, &(&1 == "join")) do
      for %{state_key: user_id} <- joined_member_events,
          # do not notify users of events their own events
          user_id != sender_id,
          {:ok, %RuleSet{} = rule_set} <- [User.get_global_rule_set(user_id)],
          {:ok, event} <- [Room.get_event(room_id, user_id, event_id, _bundle? = false)] do
        rule_set
        |> RuleSet.evaluate_event(event)
        |> perform_actions(room_id, event, user_id)
      end
    end

    :ok
  end

  @impl RadioBeam.EventHandler
  def reset_to(_number), do: {:error, :continue}

  defp perform_actions(actions, room_id, event, user_id) do
    if :notify in actions do
      notification = Notification.new(user_id, actions, event, nil, false, room_id, Time.now())

      with :ok <- Database.insert_new_notification(notification) do
        # note: for comprehensions will return [] if *any* of their
        # generators are empty Enumerables. We pull in pushers here because
        # we still want to generate notifications, even if a Pusher is not
        # configured, as some clients may implement notifications by polling
        # /notifications in the background.
        for %Pusher{} = _pusher <- get_pushers(user_id) do
          # send notif to pusher
        end
      end
    end
  end

  defp get_pushers(user_id) do
    case User.get_all_notification_pushers(user_id) do
      {:ok, pushers} -> pushers
      {:error, _} -> []
    end
  end
end
