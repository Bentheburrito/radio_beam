defmodule RadioBeam.User.Notifications.ReadMarkerServerTest do
  use ExUnit.Case, async: true

  alias RadioBeam.PubSub
  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.Notifications
  alias RadioBeam.User.Notifications.ReadMarkerServer

  setup %{test: test} do
    start_supervised!({ReadMarkerServer, name: test})

    %{user_id: creator_id} = Fixtures.create_account()
    %{user_id: user_id} = Fixtures.create_account()

    {:ok, room_id} = Room.create(creator_id)
    {:ok, _event_id} = Room.invite(room_id, creator_id, user_id)
    {:ok, _event_id} = Room.join(room_id, user_id)

    queue = {Notifications, room_id}
    Fixtures.listen_to_queue_messages(queue)

    :ok = User.put_global_notification_push_rule(user_id, :override, "anything", ["notify"], [])

    {:ok, _event_id1} = Room.send_text_message(room_id, creator_id, "'elloooo")
    {:ok, event_id2} = Room.send_text_message(room_id, creator_id, "anyone online yet?")

    {:ok, _event_id} =
      Room.send(room_id, user_id, "m.room.message", %{
        "body" => "hold your horses, I am here.",
        "msgtype" => "m.text",
        "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => event_id2}
      })

    {:ok, event_id3} =
      Room.send(room_id, creator_id, "m.room.message", %{
        "body" => "you know how I feel about horses, yet you keep bringing them up.",
        "msgtype" => "m.text",
        "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => event_id2}
      })

    Fixtures.assert_caught_up_to_event(queue, event_id3)

    :ok = PubSub.subscribe(PubSub.user_room_read_receipt_updated())

    %{room_id: room_id, creator_id: creator_id, user_id: user_id, thread_id: event_id2}
  end

  describe "upon broadcast of a read receipt PubSub event," do
    test "if thread_id == :main, any notifications for main-timeline events whose timestamp are older than the provided timestamp are marked as read",
         %{
           user_id: user_id,
           room_id: room_id
         } do
      assert [%{read: false}, %{read: false}, %{read: false, ts: first_notif_ts}] =
               Notifications.all(user_id)

      broadcast_user_room_read_receipt_updated(room_id, user_id, :main, first_notif_ts + 1)

      assert [%{read: false}, %{read: false, ts: second_notif_ts}, %{read: true}] =
               Notifications.all(user_id)

      broadcast_user_room_read_receipt_updated(room_id, user_id, :main, second_notif_ts + 1)

      assert [%{read: false, ts: third_notif_ts}, %{read: true}, %{read: true}] =
               Notifications.all(user_id)

      broadcast_user_room_read_receipt_updated(room_id, user_id, :main, third_notif_ts + 1)

      # last read is still false, because thread_type == :main
      assert [%{read: false}, %{read: true}, %{read: true}] = Notifications.all(user_id)
    end

    test "if thread_id == :unthreaded, any notifications (no matter whether they are main-timeline or threaded) whose event's timestamp is older than the provided timestamp are marked as read",
         %{
           user_id: user_id,
           room_id: room_id
         } do
      assert [%{read: false}, %{read: false}, %{read: false, ts: first_notif_ts}] =
               Notifications.all(user_id)

      broadcast_user_room_read_receipt_updated(room_id, user_id, :unthreaded, first_notif_ts + 1)

      assert [%{read: false}, %{read: false, ts: second_notif_ts}, %{read: true}] =
               Notifications.all(user_id)

      broadcast_user_room_read_receipt_updated(room_id, user_id, :unthreaded, second_notif_ts + 1)

      assert [%{read: false, ts: third_notif_ts}, %{read: true}, %{read: true}] =
               Notifications.all(user_id)

      broadcast_user_room_read_receipt_updated(room_id, user_id, :unthreaded, third_notif_ts + 1)

      # last read is true even though it's in a thread, because thread_type == :unthreaded
      assert [%{read: true}, %{read: true}, %{read: true}] = Notifications.all(user_id)
    end

    test "if thread_id is a thread ID, any notifs whose event has an m.relates_to for the given thread ID, and whose ts is older than the provided ts are marked read",
         %{
           user_id: user_id,
           room_id: room_id,
           thread_id: thread_id
         } do
      assert [%{read: false}, %{read: false}, %{read: false, ts: first_notif_ts}] =
               Notifications.all(user_id)

      broadcast_user_room_read_receipt_updated(room_id, user_id, thread_id, first_notif_ts + 1)

      # first event was not a part of the thread
      assert [%{read: false}, %{read: false, ts: second_notif_ts}, %{read: false}] =
               Notifications.all(user_id)

      broadcast_user_room_read_receipt_updated(room_id, user_id, thread_id, second_notif_ts + 1)

      # second event is the thread parent, and should (rather unintuitively)
      # NOT be considered a part of the thread. In other words, thread parents
      # are considered to be a part of the `main` timeline. This is per the
      # [spec](https://spec.matrix.org/latest/client-server-api/#threaded-read-receipts)
      assert [%{read: false, ts: third_notif_ts}, %{read: false}, %{read: false}] =
               Notifications.all(user_id)

      broadcast_user_room_read_receipt_updated(room_id, user_id, thread_id, third_notif_ts + 1)

      # last read is true, as it has an m.thread m.relates_to that points to `thread_id`
      assert [%{read: true}, %{read: false}, %{read: false}] = Notifications.all(user_id)
    end
  end

  defp broadcast_user_room_read_receipt_updated(room_id, user_id, thread_id, timestamp) do
    PubSub.broadcast(
      PubSub.user_room_read_receipt_updated(),
      {:user_room_read_receipt_updated, room_id, user_id, thread_id, timestamp}
    )

    # receiving our own msg just so we can be reasonably sure that it has at
    # least been delivered to ReadMarkerServer as well, and then we wait 5ms as
    # a hacky way to wait for it to process the msg and update Notifications
    receive do
      {:user_room_read_receipt_updated, ^room_id, ^user_id, ^thread_id, ^timestamp} -> Process.sleep(200)
    end
  end
end
