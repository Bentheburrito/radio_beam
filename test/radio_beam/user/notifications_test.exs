defmodule RadioBeam.User.NotificationsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.Notification
  alias RadioBeam.User.Notifications

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
      assert [] = Notifications.all_notifications(creator_id)
      assert [] = Notifications.all_notifications(user_id)

      {:ok, event_id} = Room.send_text_message(room_id, user_id, "G'DAY LADS, gamenight is on!")

      :pong = Room.Server.ping(room_id)

      assert [%Notification{event: %{id: ^event_id}}] = Notifications.all_notifications(creator_id)
      assert [] = Notifications.all_notifications(user_id)
    end

    test "does not insert a Notification if the event doesn't match any push rule", %{
      room_id: room_id,
      creator_id: creator_id,
      user_id: user_id
    } do
      assert [] = Notifications.all_notifications(creator_id)
      assert [] = Notifications.all_notifications(user_id)

      {:ok, event_id} = Room.send_text_message(room_id, user_id, "G'DAY LADS, tonight we game!")

      :pong = Room.Server.ping(room_id)

      assert [] = Notifications.all_notifications(creator_id)
      assert [] = Notifications.all_notifications(user_id)
    end
  end
end
