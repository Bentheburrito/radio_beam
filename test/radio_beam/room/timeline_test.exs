defmodule RadioBeam.Room.TimelineTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline
  alias RadioBeam.Room.Timeline.Chunk
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.Sync.NextBatch
  alias RadioBeam.User.EventFilter

  setup do
    creator = Fixtures.create_account()
    account = Fixtures.create_account()
    device = Fixtures.create_device(account.user_id)

    %{creator: creator, account: account, device: device}
  end

  describe "get_messages/5,6" do
    setup %{creator: creator, account: account} do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)
      {:ok, _event_id} = Room.join(room_id, account.user_id)

      Room.send_text_message(room_id, creator.user_id, "sup")
      Room.send_text_message(room_id, account.user_id, "yo")
      Room.send_text_message(room_id, account.user_id, "what is this room about")
      Room.send_text_message(room_id, creator.user_id, "idk")
      Room.send_text_message(room_id, creator.user_id, "wait yes I do")
      Room.set_name(room_id, creator.user_id, "Get Messages Pagination")
      Room.send_text_message(room_id, creator.user_id, "there we go")
      Room.send_text_message(room_id, account.user_id, "so you're just using me to test something?")
      Room.send_text_message(room_id, creator.user_id, "yeah")
      Room.send_text_message(room_id, account.user_id, "wow")
      Room.send_text_message(room_id, creator.user_id, "?")
      Room.send_text_message(room_id, account.user_id, "I thought I was more than that to you")

      Room.leave(room_id, account.user_id, "you can't trust anyone in this industry")

      %{room_id: room_id}
    end

    test "can successfully paginate backwards through events in a room using a NextBatch token", %{
      room_id: room_id,
      creator: %{user_id: creator_id} = creator,
      account: %{user_id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})

      device = Fixtures.create_device(creator.user_id)

      now = System.os_time(:millisecond)

      [%{id: tip_event_id}] = room_id |> Room.View.timeline_event_stream!(user_id, :tip) |> Enum.take(1)
      start_token = NextBatch.new!(now, %{room_id => tip_event_id}, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token2, end: end_token}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :tip, filter: filter)

      assert NextBatch.topologically_equal?(start_token, start_token2)

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state, Event)

      assert [
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.message"}
             ] =
               events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token3, end: end_token2}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token, :backward}, filter: filter)

      assert NextBatch.topologically_equal?(end_token, start_token3)

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state, Event)

      assert [
               %{type: "m.room.message", content: %{"body" => "wow"}},
               %{type: "m.room.message", content: %{"body" => "yeah"}},
               %{type: "m.room.message", content: %{"body" => "so you're just using me to test something?"}}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token4, end: end_token3}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token2, :backward}, filter: filter)

      assert NextBatch.topologically_equal?(end_token2, start_token4)

      assert 1 = Enum.count(state)

      assert [
               %{type: "m.room.message", content: %{"body" => "there we go"}},
               %{type: "m.room.name", content: %{"name" => "Get Messages Pagination"}},
               %{type: "m.room.message", content: %{"body" => "wait yes I do"}}
             ] = events

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 30}}})

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token5, end: :no_more_events}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token3, :backward}, filter: filter)

      assert NextBatch.topologically_equal?(end_token3, start_token5)

      assert 12 = Enum.count(events)
      assert 2 = Enum.count(state)
    end

    test "can successfully paginate forward events in a room after a sync", %{
      room_id: room_id,
      creator: %{user_id: creator_id} = creator,
      account: %{user_id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})
      device = Fixtures.create_device(creator.user_id)

      now = System.os_time(:millisecond)

      [%{id: tip_event_id}] = room_id |> Room.View.timeline_event_stream!(user_id, :tip) |> Enum.take(1)
      start_token = NextBatch.new!(now, %{room_id => tip_event_id}, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token2, end: end_token}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :tip, filter: filter)

      assert NextBatch.topologically_equal?(start_token, start_token2)

      assert [
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.message"}
             ] = events

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state, Event)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: end_token2, end: end_token3}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token, :forward})

      assert NextBatch.topologically_equal?(end_token, end_token2)

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state, Event)

      assert [
               %{type: "m.room.message"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.member"}
             ] = events

      Room.send(room_id, creator.user_id, "m.room.message", %{"msgtype" => "m.text", "body" => "welp"})

      assert {:ok, %Chunk{timeline_events: events, state_events: _state, start: end_token4, end: _}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token, :forward})

      assert NextBatch.topologically_equal?(end_token, end_token4)

      assert [
               %{type: "m.room.message"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "welp"}}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: _state, start: end_token5, end: end_token6}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token3, :forward})

      assert NextBatch.topologically_equal?(end_token3, end_token5)

      refute end_token6 == :no_more_events

      assert [%{type: "m.room.message", content: %{"body" => "welp"}}] = events
    end

    test "can successfully paginate forward from the beginning of a room", %{
      room_id: room_id,
      creator: creator,
      account: %{user_id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 10}}})
      device = Fixtures.create_device(creator.user_id)

      now = System.os_time(:millisecond)

      [%{id: root_event_id}] = room_id |> Room.View.timeline_event_stream!(user_id, :root) |> Enum.take(1)
      start_token = NextBatch.new!(now, %{room_id => root_event_id}, :backward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token2, end: end_token}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :root, filter: filter)

      assert NextBatch.topologically_equal?(start_token, start_token2)

      assert 2 = Enum.count(state)

      assert [
               %{type: "m.room.create"},
               %{type: "m.room.member"},
               %{type: "m.room.power_levels"},
               %{type: "m.room.join_rules"},
               %{type: "m.room.history_visibility"},
               %{type: "m.room.guest_access"},
               %{type: "m.room.member", content: %{"membership" => "invite"}},
               %{type: "m.room.member", content: %{"membership" => "join"}},
               %{content: %{"msgtype" => "m.text", "body" => "sup"}},
               %{content: %{"msgtype" => "m.text", "body" => "yo"}}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: end_token2, end: end_token3}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token, :forward}, filter: filter)

      assert NextBatch.topologically_equal?(end_token, end_token2)

      assert 2 = Enum.count(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "what is this room about"}},
               %{content: %{"msgtype" => "m.text", "body" => "idk"}},
               %{content: %{"msgtype" => "m.text", "body" => "wait yes I do"}},
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}},
               %{content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}},
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{content: %{"msgtype" => "m.text", "body" => "wow"}},
               %{content: %{"msgtype" => "m.text", "body" => "?"}},
               %{content: %{"msgtype" => "m.text", "body" => "I thought I was more than that to you"}}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: end_token4, end: %NextBatch{} = _next}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token3, :forward}, filter: filter)

      assert NextBatch.topologically_equal?(end_token3, end_token4)

      assert 1 = Enum.count(state)
      [%{type: "m.room.member", content: %{"membership" => "leave"}}] = events
    end

    test "can successfully paginate backward from the end of a room", %{
      room_id: room_id,
      creator: creator,
      account: %{user_id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 10}}})
      device = Fixtures.create_device(creator.user_id)

      now = System.os_time(:millisecond)

      [%{id: tip_event_id}] = room_id |> Room.View.timeline_event_stream!(user_id, :tip) |> Enum.take(1)
      start_token = NextBatch.new!(now, %{room_id => tip_event_id}, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token2, end: end_token}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :tip, filter: filter)

      assert NextBatch.topologically_equal?(start_token, start_token2)

      assert 2 = Enum.count(state)

      assert [
               %{type: "m.room.member", content: %{"membership" => "leave"}},
               %{content: %{"msgtype" => "m.text", "body" => "I thought I was more than that to you"}},
               %{content: %{"msgtype" => "m.text", "body" => "?"}},
               %{content: %{"msgtype" => "m.text", "body" => "wow"}},
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}},
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}},
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "wait yes I do"}},
               %{content: %{"msgtype" => "m.text", "body" => "idk"}}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token3, end: end_token2}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token, :backward}, filter: filter)

      assert NextBatch.topologically_equal?(start_token3, end_token)

      assert 2 = Enum.count(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "what is this room about"}},
               %{content: %{"msgtype" => "m.text", "body" => "yo"}},
               %{content: %{"msgtype" => "m.text", "body" => "sup"}},
               %{type: "m.room.member", content: %{"membership" => "join"}},
               %{type: "m.room.member", content: %{"membership" => "invite"}},
               %{type: "m.room.guest_access"},
               %{type: "m.room.history_visibility"},
               %{type: "m.room.join_rules"},
               %{type: "m.room.power_levels"},
               %{type: "m.room.member"}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token4, end: :no_more_events}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token2, :backward}, filter: filter)

      assert NextBatch.topologically_equal?(start_token4, end_token2)

      assert 1 = Enum.count(state)
      [%{type: "m.room.create"}] = events
    end

    test "can successfully paginate in either direction from a pagination token", %{room_id: room_id, creator: creator} do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})
      device = Fixtures.create_device(creator.user_id)

      assert {:ok, %Chunk{timeline_events: _events, state_events: _state, start: %NextBatch{}, end: end_token}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :tip, filter: filter)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token, end: end_token2}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token, :backward}, filter: filter)

      assert NextBatch.topologically_equal?(start_token, end_token)

      assert 2 = Enum.count(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "wow"}, id: event_id1},
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token2, end: end_token3}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token2, :backward}, filter: filter)

      assert NextBatch.topologically_equal?(start_token2, end_token2)

      assert 1 = Enum.count(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}, id: event_id2},
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "wait yes I do"}}
             ] = events

      expected_end_token4 = NextBatch.new!(System.os_time(:millisecond), %{room_id => event_id2}, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token3, end: end_token4}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token3, :forward}, filter: filter)

      assert NextBatch.topologically_equal?(start_token3, end_token3)
      assert NextBatch.topologically_equal?(expected_end_token4, end_token4)

      assert 1 = Enum.count(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "wait yes I do"}},
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}}
             ] = events

      expected_end_token5 = NextBatch.new!(System.os_time(:millisecond), %{room_id => event_id1}, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: start_token4, end: end_token5}} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_token2, :forward}, filter: filter)

      assert NextBatch.topologically_equal?(start_token4, end_token2)
      assert NextBatch.topologically_equal?(expected_end_token5, end_token5)

      assert 2 = Enum.count(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}},
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{content: %{"msgtype" => "m.text", "body" => "wow"}}
             ] = events
    end

    test "filters state by relevant senders when lazy_load_members is true", %{
      creator: creator,
      account: account
    } do
      account2 = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)
      {:ok, _event_id} = Room.join(room_id, account.user_id)
      {:ok, _event_id} = Room.join(room_id, account2.user_id)

      Room.send_text_message(room_id, creator.user_id, "sup")
      Room.send_text_message(room_id, account.user_id, "hi")
      Room.send_text_message(room_id, account.user_id, "creator shouldn't show up in the response")
      Room.send_text_message(room_id, account2.user_id, "true")

      filter = EventFilter.new(%{"room" => %{"state" => %{"lazy_load_members" => true}, "timeline" => %{"limit" => 2}}})

      account2_device = Fixtures.create_device(account2.user_id)

      assert {:ok, %Chunk{timeline_events: [_one, _two], state_events: state}} =
               Timeline.get_messages(room_id, account2.user_id, account2_device, :tip, filter: filter)

      for id <- [account.user_id, account2.user_id] do
        assert Enum.any?(state, &match?(%{type: "m.room.member", sender: ^id}, &1))
      end

      creator_id = creator.user_id
      refute Enum.any?(state, &match?(%{type: "m.room.member", sender: ^creator_id}, &1))
    end

    test "returned events have bundled child events", %{room_id: room_id, creator: creator} do
      {:ok, parent_id} = Room.send_text_message(room_id, creator.user_id, "thread start")

      content = %{
        "msgtype" => "m.text",
        "body" => "we're talkin'",
        "m.relates_to" => %{"event_id" => parent_id, "rel_type" => "m.thread"}
      }

      {:ok, child_id} = Room.send(room_id, creator.user_id, "m.room.message", content)

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 2}}})

      creator_device_id = Fixtures.create_device(creator.user_id)

      {:ok, %Chunk{timeline_events: events}} =
        Timeline.get_messages(room_id, creator.user_id, creator_device_id, :tip, filter: filter)

      assert [
               %{id: ^child_id},
               %{
                 id: ^parent_id,
                 bundled_events: [%{id: ^child_id}]
               }
             ] = events
    end
  end
end
