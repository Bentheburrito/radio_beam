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

  require Logger

  @max_notifications_per_user 500
  def max_per_user, do: @max_notifications_per_user

  defdelegate all(user_id, limit), to: Database, as: :all_notifications
  defdelegate all(user_id, limit, older_than_ts), to: Database, as: :all_notifications

  @default_notification_limit 30
  def all(user_id), do: all(user_id, @default_notification_limit)

  def mark_read(user_id, older_than_ts \\ Time.now(), fields_to_match \\ []) do
    user_id
    |> all(@max_notifications_per_user)
    |> filter_by_fields(fields_to_match)
    |> filter_for_older(older_than_ts)
    |> Enum.each(&mark_notification_read(&1))
  end

  defp filter_by_fields(notifs, []), do: notifs

  defp filter_by_fields(notifs, fields) do
    Stream.filter(notifs, fn %Notification{} = notif ->
      Enum.all?(fields, fn
        {:room_id, room_id} ->
          notif.room_id == room_id

        # user is on a client that doesn't understand threaded read receipts,
        # so I think the best UX is to mark everything as read. The alternative
        # is to behave like `:main` was specified, but that means that if the
        # user has threaded read receipts and never uses a client that supports
        # threads, they're "unreachable," and they would never be acknowledged,
        # leaving them with an "unread" count forever.
        {:thread_id, :unthreaded} ->
          true

        {:thread_id, :main} ->
          notif.event.content["m.relates_to"]["rel_type"] != "m.thread"

        {:thread_id, thread_id} ->
          notif.event.content["m.relates_to"]["rel_type"] == "m.thread" and
            notif.event.content["m.relates_to"]["event_id"] == thread_id
      end)
    end)
  end

  defp filter_for_older(notifs, older_than_ts), do: Stream.filter(notifs, &(&1.ts < older_than_ts))

  defp mark_notification_read(%Notification{} = notification) do
    notification.read
    |> put_in(true)
    |> upsert_notification(@max_notifications_per_user)
  end

  @max_count 99
  def unread_in_room_count(user_id, room_id) do
    user_id
    |> all(@max_count)
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

      with :ok <- upsert_notification(notification, @max_notifications_per_user) do
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

  defp upsert_notification(%Notification{} = notification, max_per_user) do
    with {:error, error} <- Database.upsert_notification(notification, max_per_user) do
      Logger.error("#{__MODULE__}.upsert_notification/2: #{inspect(error)}")
    end
  end

  defp get_pushers(user_id) do
    case User.get_all_notification_pushers(user_id) do
      {:ok, pushers} -> pushers
      {:error, _} -> []
    end
  end
end
