defmodule RadioBeam.Room.TimelineTest do
  use ExUnit.Case, async: true

  alias RadioBeam.PDU
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.Room.Timeline
  alias RadioBeam.Room.Timeline.Chunk
  alias RadioBeam.User.EventFilter

  setup do
    creator = Fixtures.user()
    {user, device} = Fixtures.device(Fixtures.user())

    %{creator: creator, user: user, device: device}
  end

  describe "get_messages/5,6" do
    setup %{creator: creator, user: user} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "sup"})
      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "yo"})
      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "what is this room about"})
      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "idk"})
      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "wait yes I do"})
      Room.set_name(room_id, creator.id, "Get Messages Pagination")
      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "there we go"})

      Room.send(room_id, user.id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "so you're just using me to test something?"
      })

      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "yeah"})
      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "wow"})
      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "?"})

      Room.send(room_id, user.id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "I thought I was more than that to you"
      })

      Room.leave(room_id, user.id, "you can't trust anyone in this industry")

      %{room_id: room_id}
    end

    test "can successfully paginate backwards through events in a room using a PaginationToken", %{
      room_id: room_id,
      creator: %{id: creator_id} = creator,
      user: %{id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})

      {creator, device} = Fixtures.device(creator)

      {:ok, %PDU{} = tip_pdu} = EventGraph.tip(room_id)
      pagination_token = PaginationToken.new(tip_pdu, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^pagination_token, next_page: next}} =
               Timeline.get_messages(room_id, creator.id, device.id, {pagination_token, :backward}, :limit,
                 filter: filter
               )

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state)

      assert [
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.message"}
             ] =
               events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next, next_page: next2}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :backward}, :limit, filter: filter)

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state)

      assert [
               %{type: "m.room.message", content: %{"body" => "wow"}},
               %{type: "m.room.message", content: %{"body" => "yeah"}},
               %{type: "m.room.message", content: %{"body" => "so you're just using me to test something?"}}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next2, next_page: next3}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next2, :backward}, :limit, filter: filter)

      assert 1 = length(state)

      assert [
               %{type: "m.room.message", content: %{"body" => "there we go"}},
               %{type: "m.room.name", content: %{"name" => "Get Messages Pagination"}},
               %{type: "m.room.message", content: %{"body" => "wait yes I do"}}
             ] = events

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 30}}})

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next3, next_page: :no_more_events}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next3, :backward}, :limit, filter: filter)

      assert 12 = length(events)
      assert 2 = length(state)
    end

    test "can successfully paginate forward events in a room after a sync", %{
      room_id: room_id,
      creator: %{id: creator_id} = creator,
      user: %{id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})
      {creator, device} = Fixtures.device(creator)

      {:ok, %PDU{} = tip_pdu} = EventGraph.tip(room_id)
      pagination_token = PaginationToken.new(tip_pdu, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^pagination_token, next_page: next}} =
               Timeline.get_messages(room_id, creator.id, device.id, {pagination_token, :backward}, :limit,
                 filter: filter
               )

      assert [
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.message"}
             ] = events

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next, next_page: next2}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :forward}, :limit)

      assert [%{type: "m.room.member", sender: ^creator_id}, %{type: "m.room.member", sender: ^user_id}] =
               Enum.sort(state)

      assert [
               %{type: "m.room.message"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.member"}
             ] = events

      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "welp"})

      assert {:ok, %Chunk{timeline_events: events, state_events: _state, start: ^next, next_page: _}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :forward}, :limit)

      assert [
               %{type: "m.room.message"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "welp"}}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: _state, start: ^next2, next_page: next3}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next2, :forward}, :limit)

      refute next3 == :no_more_events

      assert [%{type: "m.room.message", content: %{"body" => "welp"}}] = events
    end

    test "can successfully paginate forward from the beginning of a room", %{room_id: room_id, creator: creator} do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 10}}})
      {creator, device} = Fixtures.device(creator)

      {:ok, root} = EventGraph.root(room_id)
      from = PaginationToken.new(root, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^from, next_page: next}} =
               Timeline.get_messages(room_id, creator.id, device.id, :root, :limit, filter: filter)

      assert 2 = length(state)

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

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next, next_page: next2}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :forward}, :limit, filter: filter)

      assert 2 = length(state)

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

      assert {:ok,
              %Chunk{timeline_events: events, state_events: state, start: ^next2, next_page: %PaginationToken{} = _next}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next2, :forward}, :limit, filter: filter)

      assert 1 = length(state)
      [%{type: "m.room.member", content: %{"membership" => "leave"}}] = events
    end

    test "can successfully paginate backward from the end of a room", %{room_id: room_id, creator: creator} do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 10}}})
      {creator, device} = Fixtures.device(creator)

      {:ok, tip} = EventGraph.tip(room_id)
      from = PaginationToken.new(tip, :backward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^from, next_page: next}} =
               Timeline.get_messages(room_id, creator.id, device.id, :tip, :limit, filter: filter)

      assert 2 = length(state)

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

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next, next_page: next2}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :backward}, :limit, filter: filter)

      assert 2 = length(state)

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

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next2, next_page: :no_more_events}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next2, :backward}, :limit, filter: filter)

      assert 1 = length(state)
      [%{type: "m.room.create"}] = events
    end

    test "can successfully paginate in either direction from a pagination token", %{room_id: room_id, creator: creator} do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})
      {creator, device} = Fixtures.device(creator)

      assert {:ok,
              %Chunk{timeline_events: _events, state_events: _state, start: %PaginationToken{}, next_page: prev_batch}} =
               Timeline.get_messages(room_id, creator.id, device.id, :tip, :limit, filter: filter)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^prev_batch, next_page: next}} =
               Timeline.get_messages(room_id, creator.id, device.id, {prev_batch, :backward}, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "wow"}, event_id: event_id1},
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}}
             ] = events

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next, next_page: next2}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :backward}, :limit, filter: filter)

      assert 1 = length(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}, event_id: event_id2},
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "wait yes I do"}}
             ] = events

      {:ok, end_page_2_pdu} = Repo.fetch(PDU, event_id2)
      expected_end = PaginationToken.new(end_page_2_pdu, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next2, next_page: ^expected_end}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next2, :forward}, :limit, filter: filter)

      assert 1 = length(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "wait yes I do"}},
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}}
             ] = events

      {:ok, end_page_1_pdu} = Repo.fetch(PDU, event_id1)
      expected_end = PaginationToken.new(end_page_1_pdu, :forward)

      assert {:ok, %Chunk{timeline_events: events, state_events: state, start: ^next, next_page: ^expected_end}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :forward}, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}},
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{content: %{"msgtype" => "m.text", "body" => "wow"}}
             ] = events
    end

    test "filters state by relevant senders when lazy_load_members is true", %{
      creator: creator,
      user: user
    } do
      user2 = Fixtures.user()
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)
      {:ok, _event_id} = Room.join(room_id, user.id)
      {:ok, _event_id} = Room.join(room_id, user2.id)

      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "sup"})
      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "hi"})

      Room.send(room_id, user.id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "creator shouldn't show up in the response"
      })

      Room.send(room_id, user2.id, "m.room.message", %{"msgtype" => "m.text", "body" => "true"})

      filter = EventFilter.new(%{"room" => %{"state" => %{"lazy_load_members" => true}, "timeline" => %{"limit" => 2}}})

      {user2, user2_device_id} = Fixtures.device(user2)

      assert {:ok, %Chunk{timeline_events: [_one, _two], state_events: state}} =
               Timeline.get_messages(room_id, user2.id, user2_device_id, :tip, :limit, filter: filter)

      for id <- [user.id, user2.id] do
        assert Enum.any?(state, &match?(%{type: "m.room.member", sender: ^id}, &1))
      end

      creator_id = creator.id
      refute Enum.any?(state, &match?(%{type: "m.room.member", sender: ^creator_id}, &1))
    end

    test "returned events have bundled aggregations", %{room_id: room_id, creator: creator} do
      {:ok, parent_id} = Fixtures.send_text_msg(room_id, creator.id, "thread start")
      rel = %{"m.relates_to" => %{"event_id" => parent_id, "rel_type" => "m.thread"}}
      {:ok, child_id} = Fixtures.send_text_msg(room_id, creator.id, "we're talkin'", rel)

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 2}}})

      {creator, creator_device_id} = Fixtures.device(creator)

      {:ok, %Chunk{timeline_events: events}} =
        Timeline.get_messages(room_id, creator.id, creator_device_id, :tip, :limit, filter: filter)

      assert [
               %{
                 event_id: ^parent_id,
                 unsigned: %{"m.relations" => %{"m.thread" => %{latest_event: %{event_id: ^child_id}}}}
               }
             ] = events
    end
  end

  describe "bundle_aggregations/3" do
    test "bundles aggregations for the given PDU", %{creator: creator, user: user} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      {:ok, room} = Repo.fetch(Room, room_id)

      {:ok, parent_id} = Fixtures.send_text_msg(room_id, creator.id, "thread start")
      rel = %{"m.relates_to" => %{"event_id" => parent_id, "rel_type" => "m.thread"}}
      {:ok, _child_id1} = Fixtures.send_text_msg(room_id, creator.id, "hello in the thread", rel)
      {:ok, child_id2} = Fixtures.send_text_msg(room_id, user.id, "hello I am here too", rel)

      {:ok, _leave_id} = Room.leave(room.id, user.id)

      {:ok, child_id3} = Fixtures.send_text_msg(room_id, creator.id, "wait why you leave :(", rel)

      {:ok, room} = Repo.fetch(Room, room_id)
      {:ok, parent} = Repo.fetch(PDU, parent_id)

      assert %PDU{
               event_id: ^parent_id,
               unsigned: %{"m.relations" => %{"m.thread" => %{latest_event: %{event_id: ^child_id3}, count: 3}}}
             } = Timeline.bundle_aggregations(room, parent, creator.id)

      assert %PDU{
               event_id: ^parent_id,
               unsigned: %{"m.relations" => %{"m.thread" => %{latest_event: %{event_id: ^child_id2}, count: 2}}}
             } = Timeline.bundle_aggregations(room, parent, user.id)
    end
  end
end
