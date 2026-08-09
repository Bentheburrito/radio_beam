defmodule RadioBeam.Room.View.RelatedEventsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.View.RelatedEvents

  describe "handle_pdu/2" do
    setup do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)

      %{user_id: user_id} = Fixtures.create_account()

      {:ok, _event_id} = Room.invite(room_id, creator_id, user_id)
      {:ok, _event_id} = Room.join(room_id, user_id)

      Fixtures.listen_to_queue_messages({RelatedEvents, room_id})

      %{room_id: room_id, creator_id: creator_id, user_id: user_id}
    end

    test "noop for unrelated events", %{room_id: room_id, creator_id: creator_id} do
      related_events = RelatedEvents.fetch!(room_id)

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "hello")

      Fixtures.assert_caught_up_to_event({RelatedEvents, room_id}, event_id)

      ^related_events = RelatedEvents.fetch!(room_id)
    end

    test "tracks related events", %{room_id: room_id, creator_id: creator_id, user_id: user_id} do
      {:ok, thread_root_event_id} = Room.send_text_message(room_id, creator_id, "hello")

      thread_rel = %{"event_id" => thread_root_event_id, "rel_type" => "m.thread"}

      thread_message_content =
        room_id
        |> Room.Events.text_message(user_id, "what's up")
        |> Map.fetch!("content")
        |> Map.put("m.relates_to", thread_rel)

      {:ok, thread_event1_id} = Room.send(room_id, user_id, "m.room.message", thread_message_content)

      thread_message_content =
        room_id
        |> Room.Events.text_message(creator_id, "nothing much hbu")
        |> Map.fetch!("content")
        |> Map.put("m.relates_to", thread_rel)

      {:ok, thread_event2_id} = Room.send(room_id, creator_id, "m.room.message", thread_message_content)

      Fixtures.assert_caught_up_to_event({RelatedEvents, room_id}, thread_event2_id)

      assert %RelatedEvents{related_by_event_id: %{^thread_root_event_id => related_mapset}} =
               RelatedEvents.fetch!(room_id)

      assert Enum.sort([thread_event1_id, thread_event2_id]) == Enum.sort(related_mapset)
    end
  end
end
