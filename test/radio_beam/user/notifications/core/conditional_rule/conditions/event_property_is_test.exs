defmodule RadioBeam.User.Notifications.Core.ConditionalRule.Conditions.EventPropertyIsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.View.Core.Timeline
  alias RadioBeam.User.Notifications.Core.ConditionalRule.Conditions.EventPropertyIs

  @message "Hello world, this is a message."
  setup do
    %{user_id: user_id} = Fixtures.create_account()

    {:sent, room, message_id, _} =
      "12" |> Fixtures.room(user_id) |> Fixtures.send_room_msg(user_id, @message)

    timeline = Fixtures.make_room_view(Timeline, room)

    [message_event] =
      Timeline.get_visible_events(timeline, [message_id], user_id, &Room.Chronicle.fetch_pdu!(room.chronicle, &1))
      |> Enum.to_list()

    %{room: room, timeline: timeline, user_id: user_id, message_event: message_event}
  end

  describe "new/2 returns a predicate that" do
    test "returns `true` when the given string property exactly matches", %{
      user_id: user_id,
      message_event: message_event
    } do
      {:ok, predicate} = EventPropertyIs.new("type", "m.room.message")
      assert predicate.(message_event)

      {:ok, predicate} = EventPropertyIs.new("sender", user_id)
      assert predicate.(message_event)

      {:ok, predicate} = EventPropertyIs.new("content.body", @message)
      assert predicate.(message_event)
    end

    test "returns `false` when the given string property does not exactly match", %{
      user_id: user_id,
      message_event: message_event
    } do
      {:ok, predicate} = EventPropertyIs.new("type", "m.room.topic")
      refute predicate.(message_event)

      {:ok, predicate} = EventPropertyIs.new("state_key", user_id)
      refute predicate.(message_event)

      {:ok, predicate} = EventPropertyIs.new("unknown_property", "abcde")
      refute predicate.(message_event)

      for slice_start <- 0..10,
          slice_end <- 10..String.length(@message),
          substr <- [binary_slice(@message, slice_start..slice_end)],
          substr != @message do
        {:ok, predicate} = EventPropertyIs.new("content.body", substr)
        refute predicate.(message_event)
      end
    end
  end

  describe "new/2" do
    test "returns :invalid_key when given an invalid property string" do
      assert {:error, :invalid_key} = EventPropertyIs.new(123, "hello")
      assert {:error, :invalid_key} = EventPropertyIs.new("yo" <> <<0>>, "hello")
      assert {:error, :invalid_key} = EventPropertyIs.new("yo" <> <<0xFF::8>>, "hello")
    end

    test "returns {:invalid_value, value} when given an invalid \"non-compound\" value" do
      value = %{"hello" => "world"}
      assert {:error, {:invalid_value, ^value}} = EventPropertyIs.new("content.body", value)
      value = :some_value
      assert {:error, {:invalid_value, ^value}} = EventPropertyIs.new("content.body", value)
      value = 2 ** 53
      assert {:error, {:invalid_value, ^value}} = EventPropertyIs.new("content.body", value)
      value = 1.1
      assert {:error, {:invalid_value, ^value}} = EventPropertyIs.new("content.body", value)
      value = "nullbytez" <> <<0>>
      assert {:error, {:invalid_value, ^value}} = EventPropertyIs.new("content.body", value)
    end
  end
end
