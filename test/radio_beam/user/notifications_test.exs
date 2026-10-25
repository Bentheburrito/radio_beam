defmodule RadioBeam.User.NotificationsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.Notification
  alias RadioBeam.User.Notifications

  describe "all_notifications/1,2" do
    setup do
      %{user_id: creator_id} = Fixtures.create_account()
      %{user_id: user_id} = Fixtures.create_account()

      :ok = User.put_global_notification_push_rule(user_id, :override, "blahhhhhh", ["notify"], [])

      queue = {User.RoomMemberships, user_id}
      Fixtures.listen_to_queue_messages(queue)

      {:ok, room_id} = Room.create(creator_id)
      {:ok, _event_id} = Room.invite(room_id, creator_id, user_id)
      {:ok, event_id} = Room.join(room_id, user_id)

      Fixtures.assert_caught_up_to_event(queue, event_id)

      queue = {Notifications, room_id}
      Fixtures.listen_to_queue_messages(queue)

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "yo, welcome, I hope this message alerts u")

      Fixtures.assert_caught_up_to_event(queue, event_id)

      %{user_id: user_id, creator_id: creator_id, room_id: room_id, notifs_queue: queue}
    end

    test "lists all notifications, with optional pagination token", %{
      user_id: user_id,
      creator_id: creator_id,
      room_id: room_id,
      notifs_queue: queue
    } do
      assert [%{event: %{content: %{"body" => "yo" <> _}}}] = Notifications.all(user_id)

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "you there?")

      Fixtures.assert_caught_up_to_event(queue, event_id)

      assert [%{event: %{content: %{"body" => "you there?"}}, ts: ts}, %{event: %{content: %{"body" => "yo" <> _}}}] =
               Notifications.all(user_id)

      assert [%{event: %{content: %{"body" => "yo" <> _}}}] =
               Notifications.all(user_id, 5, ts - 1)
    end

    test "lists notifications up to the limit, paginating along the way", %{
      user_id: user_id,
      creator_id: creator_id,
      room_id: room_id,
      notifs_queue: queue
    } do
      assert [%{event: %{content: %{"body" => "yo" <> _}}}] = Notifications.all(user_id)

      {:ok, _event_id} = Room.send_text_message(room_id, creator_id, "you there?")
      {:ok, _event_id} = Room.send_text_message(room_id, creator_id, "pls respond")
      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "I'm so lonely")

      Fixtures.assert_caught_up_to_event(queue, event_id)

      assert [
               %{event: %{content: %{"body" => "I'm so lonely"}}},
               %{event: %{content: %{"body" => "pls respond"}}, ts: ts}
             ] =
               Notifications.all(user_id, 2)

      assert [%{event: %{content: %{"body" => "you there?"}}, ts: ts}] =
               Notifications.all(user_id, 1, ts - 1)

      assert [%{event: %{content: %{"body" => "yo" <> _}}}] = Notifications.all(user_id, 1, ts - 1)
    end
  end

  describe "handle_event/3" do
    setup do
      %{user_id: creator_id} = Fixtures.create_account()
      %{user_id: user_id} = Fixtures.create_account()

      {:ok, room_id} = Room.create(creator_id)
      {:ok, _event_id} = Room.invite(room_id, creator_id, user_id)
      {:ok, _event_id} = Room.join(room_id, user_id)

      for user_id <- [user_id, creator_id] do
        :ok =
          User.put_global_notification_push_rule(user_id, :override, "gamenight", ["notify"], [
            %{"kind" => "event_match", "pattern" => "gamenight", "key" => "content.body"}
          ])
      end

      %{room_id: room_id, creator_id: creator_id, user_id: user_id}
    end

    test "inserts a Notification for a matching event, except for the sender", %{
      room_id: room_id,
      creator_id: creator_id,
      user_id: user_id
    } do
      queue = {Notifications, room_id}
      Fixtures.listen_to_queue_messages(queue)

      assert [] = Notifications.all(creator_id)
      assert [] = Notifications.all(user_id)

      {:ok, event_id} = Room.send_text_message(room_id, user_id, "G'DAY LADS, gamenight is on!")

      Fixtures.assert_caught_up_to_event(queue, event_id)

      assert [%Notification{event: %{id: ^event_id}}] = Notifications.all(creator_id)
      assert [] = Notifications.all(user_id)
    end

    test "does not insert a Notification if the event doesn't match any push rule", %{
      room_id: room_id,
      creator_id: creator_id,
      user_id: user_id
    } do
      assert [] = Notifications.all(creator_id)
      assert [] = Notifications.all(user_id)

      {:ok, _event_id} = Room.send_text_message(room_id, user_id, "G'DAY LADS, tonight we game!")

      :pong = Room.Server.ping(room_id)

      assert [] = Notifications.all(creator_id)
      assert [] = Notifications.all(user_id)
    end

    test "drops oldest notification if the user has too many", %{
      room_id: room_id,
      creator_id: creator_id,
      user_id: user_id
    } do
      queue = {Notifications, room_id}
      Fixtures.listen_to_queue_messages(queue)

      assert [] = Notifications.all(creator_id)

      {:ok, first_event_id} = Room.send_text_message(room_id, user_id, "G'DAY LADS, gamenight is on!")

      Fixtures.assert_caught_up_to_event(queue, first_event_id)

      assert [%Notification{event: %{id: ^first_event_id}}] = Notifications.all(creator_id)

      newest_event_id =
        Enum.reduce(2..Notifications.max_per_user(), nil, fn i, _ ->
          {:ok, event_id} = Room.send_text_message(room_id, user_id, "G'DAY LADS, gamenight is on! #{i}")
          event_id
        end)

      Fixtures.assert_caught_up_to_event(queue, newest_event_id, :timer.seconds(5))

      notifications = Notifications.all(creator_id, Notifications.max_per_user() + 1)
      assert Notifications.max_per_user() == length(notifications)
      assert Enum.any?(notifications, &(&1.event.id == first_event_id))

      {:ok, newest_event_id} = Room.send_text_message(room_id, user_id, "G'DAY LADS, gamenight is on!")

      Fixtures.assert_caught_up_to_event(queue, newest_event_id)

      notifications = Notifications.all(creator_id, Notifications.max_per_user() + 1)
      assert Notifications.max_per_user() == length(notifications)
      refute Enum.any?(notifications, &(&1.event.id == first_event_id))
      assert Enum.any?(notifications, &(&1.event.id == newest_event_id))
    end
  end
end
