defmodule RadioBeam.Room.TimelineTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.User.EventFilter

  setup do
    creator = Fixtures.create_account()
    account = Fixtures.create_account()
    device = Fixtures.create_device(account.user_id)

    %{creator: creator, account: account, device: device}
  end

  describe "get_messages/4,5" do
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

    test "can successfully paginate backwards through events in a room using the given event ID", %{
      room_id: room_id,
      creator: %{user_id: creator_id} = creator,
      account: %{user_id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})

      device = Fixtures.create_device(creator.user_id)

      [%{id: tip_event_id}] = room_id |> Room.View.timeline_event_stream!(user_id, :tip) |> Enum.take(1)

      assert {:ok, events, end_id, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :tip, filter: filter)

      assert %{id: ^tip_event_id} = hd(events)

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state, Event)

      assert [
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.message"}
             ] =
               events

      assert {:ok, events, end_id2, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id, :backward}, filter: filter)

      refute match?(%{id: ^end_id}, hd(events))

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state, Event)

      assert [
               %{type: "m.room.message", content: %{"body" => "wow"}},
               %{type: "m.room.message", content: %{"body" => "yeah"}},
               %{type: "m.room.message", content: %{"body" => "so you're just using me to test something?"}}
             ] = events

      assert {:ok, events, end_id3, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id2, :backward}, filter: filter)

      refute match?(%{id: ^end_id2}, hd(events))

      assert 1 = Enum.count(state)

      assert [
               %{type: "m.room.message", content: %{"body" => "there we go"}},
               %{type: "m.room.name", content: %{"name" => "Get Messages Pagination"}},
               %{type: "m.room.message", content: %{"body" => "wait yes I do"}}
             ] = events

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 30}}})

      assert {:ok, events, :no_more_events, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id3, :backward}, filter: filter)

      refute match?(%{id: ^end_id3}, hd(events))

      assert 12 = Enum.count(events)
      assert 2 = Enum.count(state)
    end

    test "can successfully paginate forward events in a room", %{
      room_id: room_id,
      creator: %{user_id: creator_id} = creator,
      account: %{user_id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})
      device = Fixtures.create_device(creator.user_id)

      [%{id: tip_event_id}] = room_id |> Room.View.timeline_event_stream!(user_id, :tip) |> Enum.take(1)

      assert {:ok, events, end_id, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :tip, filter: filter)

      assert %{id: ^tip_event_id} = hd(events)

      assert [
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.message"}
             ] = events

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state, Event)

      assert {:ok, events, _end_id2, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id, :forward})

      refute match?(%{id: ^end_id}, hd(events))

      assert [%{type: "m.room.member", sender: ^user_id}] = Enum.to_list(state)

      assert [
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.member"}
             ] = events

      Room.send(room_id, creator.user_id, "m.room.message", %{"msgtype" => "m.text", "body" => "welp"})

      assert {:ok, events, end_id3, _state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id, :forward})

      refute match?(%{id: ^end_id}, hd(events))

      assert [
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "welp"}}
             ] = events

      assert {:ok, [], :no_more_events, _state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id3, :forward})
    end

    test "can successfully paginate forward from the beginning of a room", %{
      room_id: room_id,
      creator: creator,
      account: %{user_id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 10}}})
      device = Fixtures.create_device(creator.user_id)

      [%{id: root_event_id}] = room_id |> Room.View.timeline_event_stream!(user_id, :root) |> Enum.take(1)

      assert {:ok, events, end_id, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :root, filter: filter)

      assert %{id: ^root_event_id} = hd(events)

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

      assert {:ok, events, end_id2, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id, :forward}, filter: filter)

      refute match?(%{id: ^end_id}, hd(events))

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

      assert {:ok, events, _end_id3, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id2, :forward}, filter: filter)

      refute match?(%{id: ^end_id2}, hd(events))

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

      [%{id: tip_event_id}] = room_id |> Room.View.timeline_event_stream!(user_id, :tip) |> Enum.take(1)

      assert {:ok, events, end_id, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :tip, filter: filter)

      assert %{id: ^tip_event_id} = hd(events)

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

      assert {:ok, events, end_id2, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id, :backward}, filter: filter)

      refute match?(%{id: ^end_id2}, hd(events))

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

      assert {:ok, events, :no_more_events, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id2, :backward}, filter: filter)

      assert 1 = Enum.count(state)
      [%{type: "m.room.create"}] = events
    end

    test "can successfully paginate in either direction from a pagination token", %{room_id: room_id, creator: creator} do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})
      device = Fixtures.create_device(creator.user_id)

      assert {:ok, _events, end_id, _state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :tip, filter: filter)

      assert {:ok, events, end_id2, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id, :backward}, filter: filter)

      refute match?(%{id: ^end_id}, hd(events))

      assert 2 = Enum.count(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "wow"}},
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{
                 content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"},
                 id: expected_end_id4
               }
             ] = events

      assert {:ok, events, end_id3, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id2, :backward}, filter: filter)

      refute match?(%{id: ^end_id2}, hd(events))

      assert 1 = Enum.count(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}},
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "wait yes I do"}}
             ] = events

      assert {:ok, events, ^expected_end_id4, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id3, :forward}, filter: filter)

      refute match?(%{id: ^end_id3}, hd(events))

      assert 2 = Enum.count(state)

      assert [
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}},
               %{content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}}
             ] = events

      assert {:ok, events, end_id5, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id2, :forward}, filter: filter)

      refute match?(%{id: ^end_id2}, hd(events))

      assert 2 = Enum.count(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{content: %{"msgtype" => "m.text", "body" => "wow"}},
               %{content: %{"msgtype" => "m.text", "body" => "?"}, id: ^end_id5}
             ] = events
    end

    test "can successfully paginate in either direction from a pagination token, to: another", %{
      room_id: room_id,
      creator: creator
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})
      device = Fixtures.create_device(creator.user_id)

      assert {:ok, _events, end_id, _state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, :tip, filter: filter)

      assert {:ok, events, end_id2, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id, :backward}, filter: filter)

      refute match?(%{id: ^end_id}, hd(events))

      expected_events = Enum.take(events, 2)
      expected_state = Enum.take(state, 2)

      assert {:ok, ^expected_events, :no_more_events, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id, :backward}, to: end_id2)

      assert ^expected_state = Enum.take(state, 2)

      assert {:ok, events, end_id3, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id2, :backward}, filter: filter)

      expected_events = Enum.take(events, 2)
      expected_state = Enum.take(state, 2)

      assert {:ok, ^expected_events, :no_more_events, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id2, :backward}, to: end_id3)

      assert ^expected_state = Enum.take(state, 2)

      assert {:ok, events, end_id4, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id3, :forward}, filter: filter)

      expected_events = Enum.take(events, 2)
      expected_state = Enum.filter(state, &Enum.any?(expected_events, fn event -> event.sender == &1.state_key end))

      assert {:ok, ^expected_events, :no_more_events, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id3, :forward}, to: end_id4)

      assert ^expected_state = Enum.take(state, 2)

      assert {:ok, events, end_id5, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id2, :forward}, filter: filter)

      expected_events = Enum.take(events, 2)
      expected_state = Enum.take(state, 2)

      assert {:ok, ^expected_events, :no_more_events, state} =
               Timeline.get_messages(room_id, creator.user_id, device.id, {end_id2, :forward}, to: end_id5)

      assert ^expected_state = Enum.take(state, 2)
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

      assert {:ok, [_one, _two], _end_id, state} =
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

      assert {:ok, events, _end_id, _state} =
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

  describe "get_context/4,5" do
    setup %{creator: creator, account: account} do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)
      {:ok, eid1} = Room.join(room_id, account.user_id)

      {:ok, eid2} = Room.send_text_message(room_id, creator.user_id, "sup")
      {:ok, eid3} = Room.send_text_message(room_id, account.user_id, "yo")
      {:ok, eid4} = Room.send_text_message(room_id, account.user_id, "what is this room about")
      {:ok, eid5} = Room.send_text_message(room_id, creator.user_id, "idk")
      {:ok, event_id} = Room.send_text_message(room_id, creator.user_id, "wait yes I do")
      {:ok, eid6} = Room.set_name(room_id, creator.user_id, "Get Messages Pagination")
      {:ok, eid7} = Room.send_text_message(room_id, creator.user_id, "there we go")
      {:ok, eid8} = Room.send_text_message(room_id, account.user_id, "so you're just using me to test something?")
      {:ok, eid9} = Room.send_text_message(room_id, creator.user_id, "yeah")
      {:ok, eid10} = Room.send_text_message(room_id, account.user_id, "wow")
      Room.send_text_message(room_id, creator.user_id, "?")
      Room.send_text_message(room_id, account.user_id, "I thought I was more than that to you")

      Room.leave(room_id, account.user_id, "you can't trust anyone in this industry")

      {:ok, not_visible_eid} = Room.send_text_message(room_id, creator.user_id, "so dramatic 🙄")

      %{
        room_id: room_id,
        event_id: event_id,
        expected_before: [eid1, eid2, eid3, eid4, eid5],
        expected_after: [eid6, eid7, eid8, eid9, eid10],
        not_visible_eid: not_visible_eid
      }
    end

    test "fetches all surrounding events, up to the given limit", %{
      room_id: room_id,
      event_id: event_id,
      expected_before: [eid1 | _] = expected_before,
      expected_after: expected_after,
      account: %{user_id: user_id}
    } do
      eid10 = List.last(expected_after)
      device = Fixtures.create_device(user_id)
      filter = %{"room" => %{"timeline" => %{"limit" => 5}}}

      assert {:ok, %{id: ^event_id}, events_before, ^eid1, events_after, ^eid10} =
               Timeline.get_context(room_id, user_id, device.id, event_id, filter: filter)

      assert Enum.sort(expected_before) == events_before |> Stream.map(& &1.id) |> Enum.sort()
      assert Enum.sort(expected_after) == events_after |> Stream.map(& &1.id) |> Enum.sort()
    end

    test "does not surface events that the user isn't allowed to see", %{
      room_id: room_id,
      expected_after: [_, _, _, _, eid10],
      not_visible_eid: not_visible_eid,
      account: %{user_id: user_id},
      creator: %{user_id: creator_id}
    } do
      creator_device = Fixtures.create_device(creator_id)
      device = Fixtures.create_device(user_id)
      filter = %{"room" => %{"timeline" => %{"limit" => 5}}}

      assert {:ok, %{id: ^eid10}, _events_before, _start_token, events_after_user, _end_id} =
               Timeline.get_context(room_id, user_id, device.id, eid10, filter: filter)

      assert {:ok, %{id: ^eid10}, _events_before, _start_token, events_after_creator, _end_id} =
               Timeline.get_context(room_id, creator_id, creator_device.id, eid10, filter: filter)

      refute Enum.any?(events_after_user, &(&1.id == not_visible_eid))
      assert Enum.any?(events_after_creator, &(&1.id == not_visible_eid))
    end
  end
end
