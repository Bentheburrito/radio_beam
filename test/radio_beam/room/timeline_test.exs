defmodule RadioBeam.Room.TimelineTest do
  use ExUnit.Case, async: true

  alias RadioBeam.PDU
  alias RadioBeam.Room.EventGraph
  alias RadioBeam.Room
  alias RadioBeam.Room.EventGraph.PaginationToken
  alias RadioBeam.Room.Timeline
  alias RadioBeam.User.EventFilter

  setup do
    creator = Fixtures.user()
    {user, device} = Fixtures.device(Fixtures.user())

    %{creator: creator, user: user, device: device}
  end

  describe "sync/4 performing an initial sync" do
    test "successfully syncs all events in a newly created room", %{creator: creator, user: user, device: device} do
      {:ok, room_id1} = Room.create(creator)
      {:ok, room_id2} = Room.create(creator, name: "The Chatroom")
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: []}, timeline: timeline}},
                 invite: %{^room_id2 => %{invite_state: invite_state}}
               }
             } =
               Timeline.sync([room_id1, room_id2], user.id, device.id)

      user_id = user.id

      assert %{
               sync: :complete,
               events: [
                 %{type: "m.room.create"},
                 %{type: "m.room.member"},
                 %{type: "m.room.power_levels"},
                 %{type: "m.room.join_rules"},
                 %{type: "m.room.history_visibility"},
                 %{type: "m.room.guest_access"},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
               ]
             } =
               timeline

      assert 4 = length(invite_state.events)
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.name"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.member", "state_key" => ^user_id}, &1))

      refute is_map_key(timeline, :prev_batch)
    end

    test "successfully syncs, bundling aggregate events", %{creator: creator, user: user, device: device} do
      {:ok, room_id1} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      {:ok, thread_id} = Fixtures.send_text_msg(room_id1, user.id, "I have news -> 🧵")

      thread_rel = %{"m.relates_to" => %{"event_id" => thread_id, "rel_type" => "m.thread"}}

      Fixtures.send_text_msg(room_id1, user.id, "it's @bob's birthday!!!!!!!!", thread_rel)
      Process.sleep(1)

      {:ok, latest_event_id} = Fixtures.send_text_msg(room_id1, creator.id, "happy bday @bob!!!!!", thread_rel)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: []}, timeline: timeline}}
               }
             } =
               Timeline.sync([room_id1], user.id, device.id)

      user_id = user.id

      assert %{
               sync: :complete,
               events: [
                 %{type: "m.room.create"},
                 %{type: "m.room.member"},
                 %{type: "m.room.power_levels"},
                 %{type: "m.room.join_rules"},
                 %{type: "m.room.history_visibility"},
                 %{type: "m.room.guest_access"},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}},
                 %{
                   type: "m.room.message",
                   unsigned: %{
                     "m.relations" => %{
                       "m.thread" => %{
                         latest_event: %{event_id: ^latest_event_id},
                         count: 2,
                         current_user_participated: true
                       }
                     }
                   }
                 }
               ]
             } =
               timeline
    end

    test "successfully syncs all events up to n", %{creator: creator, user: user, device: device} do
      {:ok, room_id1} = Room.create(creator)
      {:ok, room_id2} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 5}}})

      assert %{
               rooms: %{
                 join: %{
                   ^room_id1 => %{
                     state: %{events: state},
                     timeline: timeline
                   }
                 },
                 invite: %{^room_id2 => %{invite_state: invite_state}}
               }
             } =
               Timeline.sync([room_id1, room_id2], user.id, device.id, filter: filter)

      assert Enum.any?(state, &match?(%{type: "m.room.create"}, &1))
      assert Enum.any?(state, &match?(%{type: "m.room.member"}, &1))
      assert Enum.any?(state, &match?(%{type: "m.room.power_levels"}, &1))
      # assert %{event_id: "$" <> _ = event_id} = Enum.find(state, &(&1.type == "m.room.power_levels"))

      assert %{
               sync: %PaginationToken{} = token,
               events: [
                 %{type: "m.room.join_rules", event_id: event_id},
                 %{type: "m.room.history_visibility"},
                 %{type: "m.room.guest_access"},
                 %{type: "m.room.member"},
                 %{type: "m.room.member"}
               ]
             } =
               timeline

      assert event_id in token.event_ids

      user_id = user.id

      assert 3 = length(invite_state.events)
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.member", "state_key" => ^user_id}, &1))
    end
  end

  describe "sync/4 performing a follow-up sync" do
    test "successfully syncs all new events when there aren't many", %{creator: creator, user: user, device: device} do
      {:ok, random_room_just_for_init_sync} = Room.create(user)
      assert %{rooms: %{}, next_batch: since} = Timeline.sync([random_room_just_for_init_sync], user.id, device.id)

      # ---

      {:ok, room_id1} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: []}, timeline: timeline}},
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: since
             } =
               Timeline.sync([room_id1], user.id, device.id, since: since)

      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      user_id = user.id

      assert %{
               sync: :complete,
               events: [
                 %{type: "m.room.create"},
                 %{type: "m.room.member"},
                 %{type: "m.room.power_levels"},
                 %{type: "m.room.join_rules"},
                 %{type: "m.room.history_visibility"},
                 %{type: "m.room.guest_access"},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
               ]
             } =
               timeline

      refute is_map_key(timeline, :prev_batch)

      # ---

      {:ok, room_id2} = Room.create(creator, name: "Notes")
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)

      assert %{
               rooms: %{
                 join: join_map,
                 invite: %{^room_id2 => %{invite_state: invite_state}}
               },
               next_batch: since
             } =
               Timeline.sync([room_id1, room_id2], user.id, device.id, since: since)

      assert 0 = map_size(join_map)

      user_id = user.id

      assert 4 = length(invite_state.events)
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.name"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.member", "state_key" => ^user_id}, &1))

      # ---

      %{id: rando_id} = Fixtures.user()
      {:ok, _event_id} = Room.invite(room_id1, creator.id, rando_id)
      {:ok, _event_id} = Room.join(room_id1, rando_id)

      assert %{
               rooms: %{join: %{^room_id1 => %{state: %{events: []}, timeline: timeline}}, invite: invite_map},
               next_batch: since
             } =
               Timeline.sync([room_id1, room_id2], user.id, device.id, since: since)

      assert 0 = map_size(invite_map)

      assert %{
               sync: :complete,
               events: [
                 %{type: "m.room.member", state_key: ^rando_id, content: %{"membership" => "invite"}},
                 %{type: "m.room.member", state_key: ^rando_id, content: %{"membership" => "join"}}
               ]
             } =
               timeline

      # ---

      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "should be able to see this")
      {:ok, _event_id} = Room.leave(room_id1, user.id, "byeeeeeeeeeeeeeee")
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "alright user is gone let's party!!!!!!!!")

      filter = EventFilter.new(%{"room" => %{"include_leave" => true}})

      assert %{
               rooms: %{
                 join: join_map,
                 invite: invite_map,
                 leave: %{^room_id1 => %{state: %{events: state}, timeline: timeline}}
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1, room_id2], user.id, device.id, since: since, filter: filter)

      assert 0 = map_size(join_map)
      assert 0 = map_size(invite_map)

      refute state
             |> Stream.filter(&(&1["type"] == "m.room.name"))
             |> Enum.any?(&(&1["content"]["name"] =~ "let's party!"))

      creator_id = creator.id

      assert %{
               sync: :complete,
               events: [
                 %{
                   type: "m.room.name",
                   sender: ^creator_id,
                   content: %{"name" => "should be able to see this"}
                 },
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "leave"}}
               ]
             } =
               timeline
    end

    test "successfully syncs, responding with a partial timeline when necessary", %{
      creator: creator,
      user: user,
      device: device
    } do
      {:ok, room_id1} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: []}, timeline: timeline}},
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: since
             } =
               Timeline.sync([room_id1], user.id, device.id)

      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      user_id = user.id

      assert %{
               sync: :complete,
               events: [
                 %{type: "m.room.create"},
                 %{type: "m.room.member"},
                 %{type: "m.room.power_levels"},
                 %{type: "m.room.join_rules"},
                 %{type: "m.room.history_visibility"},
                 %{type: "m.room.guest_access"},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
               ]
             } =
               timeline

      refute is_map_key(timeline, :prev_batch)

      # --- 

      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "Name update outside of window")
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "First name update")
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "Second name update")

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 2}}})

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: state}, timeline: timeline}},
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: since
             } =
               Timeline.sync([room_id1], user.id, device.id, since: since, filter: filter)

      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      assert [_] = state

      assert %{
               sync: %PaginationToken{} = token,
               events: [
                 %{type: "m.room.name", content: %{"name" => "First name update"}, event_id: event_id},
                 %{type: "m.room.name", content: %{"name" => "Second name update"}}
               ]
             } =
               timeline

      assert event_id in token.event_ids

      # ---

      Room.set_name(room_id1, creator.id, "THIS SHOULD SHOW UP IN FULL STATE ONLY")
      Room.send(room_id1, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello? Is anyone there?"})
      Room.send(room_id1, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "HE CAN'T HIT"})

      assert %{
               rooms: %{join: %{^room_id1 => %{state: %{events: [%{type: "m.room.name"}]}, timeline: timeline}}},
               next_batch: _since
             } =
               Timeline.sync([room_id1], user.id, device.id, since: since, filter: filter)

      assert %{
               sync: %PaginationToken{},
               events: [
                 %{type: "m.room.message", content: %{"body" => "Hello? Is anyone there?"}},
                 %{type: "m.room.message", content: %{"body" => "HE CAN'T HIT"}}
               ]
             } =
               timeline

      assert %{
               rooms: %{join: %{^room_id1 => %{state: %{events: state}, timeline: timeline}}},
               next_batch: _since
             } =
               Timeline.sync([room_id1], user.id, device.id, since: since, filter: filter, full_state?: true)

      assert 8 = length(state)

      assert %{
               sync: %PaginationToken{},
               events: [
                 %{type: "m.room.message", content: %{"body" => "Hello? Is anyone there?"}},
                 %{type: "m.room.message", content: %{"body" => "HE CAN'T HIT"}}
               ]
             } =
               timeline
    end
  end

  describe "sync/4 with a filter" do
    test "applies timeline- and state-specific rooms and not_rooms filters", %{
      creator: creator,
      user: user,
      device: device
    } do
      {:ok, room_id1} = Room.create(creator, name: "Introductions")
      {:ok, room_id2} = Room.create(creator, name: "General", topic: "whatever you wanna talk about")
      {:ok, room_id3} = Room.create(creator, name: "Media & Photos")

      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id3, creator.id, user.id)

      {:ok, _event_id} = Room.join(room_id1, user.id)
      {:ok, _event_id} = Room.join(room_id2, user.id)
      {:ok, _event_id} = Room.join(room_id3, user.id)

      {:ok, _event_id} = Room.set_name(room_id2, creator.id, "General Chat")

      event_filter = %{"rooms" => [room_id1, room_id2], "not_rooms" => [room_id1]}
      filter = EventFilter.new(%{"room" => %{"timeline" => event_filter, "state" => event_filter}})

      assert %{
               rooms: %{
                 join: %{^room_id2 => %{state: %{events: []}, timeline: timeline}} = join_map,
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1, room_id2, room_id3], user.id, device.id, filter: filter)

      assert 1 = map_size(join_map)
      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      assert %{
               sync: :complete,
               events: [%{type: "m.room.create"} | _] = events
             } =
               timeline

      assert %{type: "m.room.name", content: %{"name" => "General Chat"}} = List.last(events)
    end

    test "applies `room`-key-level rooms and not_rooms filters", %{creator: creator, user: user, device: device} do
      {:ok, room_id1} = Room.create(creator, name: "Introductions")
      {:ok, room_id2} = Room.create(creator, name: "General", topic: "whatever you wanna talk about")
      {:ok, room_id3} = Room.create(creator, name: "Media & Photos")

      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id3, creator.id, user.id)

      {:ok, _event_id} = Room.join(room_id1, user.id)
      {:ok, _event_id} = Room.join(room_id2, user.id)
      {:ok, _event_id} = Room.join(room_id3, user.id)

      {:ok, _event_id} = Room.set_name(room_id2, creator.id, "General Chat")

      filter = EventFilter.new(%{"room" => %{"rooms" => [room_id1, room_id2], "not_rooms" => [room_id1]}})

      assert %{
               rooms: %{
                 join: %{^room_id2 => %{state: %{events: []}, timeline: timeline}} = join_map,
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1, room_id2, room_id3], user.id, device.id, filter: filter)

      assert 1 = map_size(join_map)
      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      assert %{
               sync: :complete,
               events: [%{type: "m.room.create"} | _] = events
             } =
               timeline

      assert %{type: "m.room.name", content: %{"name" => "General Chat"}} = List.last(events)
    end

    test "applies lazy_load_members to state delta", %{creator: creator, user: user} do
      user2 = Fixtures.user()
      user3 = Fixtures.user()

      {:ok, room_id1} = Room.create(creator, name: "Introductions")
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user2.id)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user3.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)
      {:ok, _event_id} = Room.join(room_id1, user2.id)
      {:ok, _event_id} = Room.join(room_id1, user3.id)

      send_msg = &Room.send(&1, &2, "m.room.message", %{"msgtype" => "m.text", "body" => &3})
      {:ok, _event_id} = send_msg.(room_id1, creator.id, "welcome all")
      {:ok, _event_id} = send_msg.(room_id1, user.id, "hello!")
      {:ok, _event_id} = send_msg.(room_id1, user2.id, "hi")
      {:ok, _event_id} = send_msg.(room_id1, user3.id, "yo")

      filter = EventFilter.new(%{"room" => %{"state" => %{"lazy_load_members" => true}, "timeline" => %{"limit" => 2}}})
      {user3, %{id: user3_device_id}} = Fixtures.device(user3)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: state}, timeline: %{events: [_one, _two]}}}
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1], user3.id, user3_device_id, filter: filter)

      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user.id))

      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user2.id))
      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user3.id))

      # the creator's membership event should always be present

      {creator, %{id: creator_device_id}} = Fixtures.device(creator)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: state}, timeline: %{events: [_one, _two]}}}
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1], creator.id, creator_device_id, filter: filter)

      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user.id))
      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user2.id))
      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user3.id))
    end

    test "applies lazy_load_members to state delta, excluding redundant membership events from state unless the filter requests it",
         %{
           creator: creator,
           user: user
         } do
      user2 = Fixtures.user()
      user3 = Fixtures.user()

      {:ok, room_id1} = Room.create(creator, name: "Introductions")
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user2.id)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user3.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)
      {:ok, _event_id} = Room.join(room_id1, user2.id)
      {:ok, _event_id} = Room.join(room_id1, user3.id)

      send_msg = &Room.send(&1, &2, "m.room.message", %{"msgtype" => "m.text", "body" => &3})
      {:ok, _event_id} = send_msg.(room_id1, creator.id, "welcome all")
      {:ok, _event_id} = send_msg.(room_id1, user.id, "hello!")
      {:ok, _event_id} = send_msg.(room_id1, user2.id, "hi")
      {:ok, _event_id} = send_msg.(room_id1, user3.id, "yo")

      filter = EventFilter.new(%{"room" => %{"state" => %{"lazy_load_members" => true}, "timeline" => %{"limit" => 2}}})
      {user, device} = Fixtures.device(user)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: state}, timeline: %{events: [_one, _two]}}}
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1], user3.id, device.id, filter: filter)

      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user.id))

      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user2.id))
      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user3.id))

      # initial sync again - memberships already sent last time should not be 
      # sent again (unless its the syncing user's membership)

      {:ok, _event_id} = send_msg.(room_id1, user2.id, "so what is the plan")
      {:ok, _event_id} = send_msg.(room_id1, user.id, "brunch tomorrow @ 11")

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: state}, timeline: %{events: [_one, _two]}}}
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1], user3.id, device.id, filter: filter)

      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user2.id))

      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user.id))
      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user3.id))

      # adjust filter to request redundant memberships

      redundant_filter =
        EventFilter.new(%{
          "room" => %{
            "state" => %{"lazy_load_members" => true, "include_redundant_members" => true},
            "timeline" => %{"limit" => 2}
          }
        })

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: state}, timeline: %{events: [_one, _two]}}}
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1], user3.id, device.id, filter: redundant_filter)

      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == creator.id))

      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user.id))
      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user2.id))
      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user3.id))

      # and once more without redundant members...should only be the syncing user
      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: %{events: state}, timeline: %{events: [_one, _two]}}}
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1], user3.id, device.id, filter: filter)

      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user.id))
      refute Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user2.id))

      assert Enum.find(state, &(&1.type == "m.room.member" and &1.state_key == user3.id))
    end
  end

  describe "sync/4 with a timeout" do
    test "will wait for the next room event", %{creator: creator, user: user, device: device} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: %{events: []}, timeline: timeline}}
               },
               next_batch: since
             } =
               Timeline.sync([room_id], user.id, device.id)

      user_id = user.id

      assert %{
               sync: :complete,
               events: [
                 %{type: "m.room.create"},
                 %{type: "m.room.member"},
                 %{type: "m.room.power_levels"},
                 %{type: "m.room.join_rules"},
                 %{type: "m.room.history_visibility"},
                 %{type: "m.room.guest_access"},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
               ]
             } =
               timeline

      timeout = 800
      wait_for = div(timeout, 2)
      time_before_wait = :os.system_time(:millisecond)

      sync_task =
        Task.async(fn -> Timeline.sync([room_id], user.id, device.id, timeout: timeout, since: since) end)

      Process.sleep(wait_for)
      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello!!"})

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: %{events: []}, timeline: timeline}}
               }
             } = Task.await(sync_task)

      assert %{sync: :complete, events: [%{type: "m.room.message"}]} = timeline

      assert :os.system_time(:millisecond) - time_before_wait >= wait_for
    end

    test "will wait for the next invite event", %{creator: creator, user: user, device: device} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: %{events: []}, timeline: timeline}}
               },
               next_batch: since
             } =
               Timeline.sync([room_id], user.id, device.id)

      user_id = user.id

      assert %{
               sync: :complete,
               events: [
                 %{type: "m.room.create"},
                 %{type: "m.room.member"},
                 %{type: "m.room.power_levels"},
                 %{type: "m.room.join_rules"},
                 %{type: "m.room.history_visibility"},
                 %{type: "m.room.guest_access"},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
               ]
             } =
               timeline

      timeout = 800
      wait_for = div(timeout, 2)
      time_before_wait = :os.system_time(:millisecond)

      sync_task =
        Task.async(fn -> Timeline.sync([room_id], user.id, device.id, timeout: timeout, since: since) end)

      Process.sleep(wait_for)
      {:ok, room_id2} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)

      assert %{
               rooms: %{
                 invite: %{^room_id2 => %{invite_state: %{events: _events}}}
               }
             } = Task.await(sync_task)

      assert :os.system_time(:millisecond) - time_before_wait >= wait_for
    end

    test "will wait for the next room event that matches the filter", %{creator: creator, user: user, device: device} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: %{events: []}, timeline: _timeline}}
               },
               next_batch: since
             } =
               Timeline.sync([room_id], user.id, device.id)

      time_before_wait = :os.system_time(:millisecond)

      event_filter = %{"not_senders" => [creator.id]}
      filter = EventFilter.new(%{"room" => %{"timeline" => event_filter, "state" => event_filter}})

      sync_task =
        Task.async(fn -> Timeline.sync([room_id], user.id, device.id, filter: filter, timeout: 1000, since: since) end)

      Process.sleep(100)
      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello"})

      assert is_nil(Task.yield(sync_task, 0))

      Process.sleep(100)
      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello"})

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: %{events: []}, timeline: timeline}}
               }
             } = Task.await(sync_task)

      assert %{
               sync: :complete,
               events: [%{type: "m.room.message"}]
             } =
               timeline

      assert :os.system_time(:millisecond) - time_before_wait >= 200
    end

    test "will timeout", %{creator: creator, user: user, device: device} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: %{events: []}, timeline: _timeline}}
               },
               next_batch: since
             } =
               Timeline.sync([room_id], user.id, device.id)

      %{rooms: rooms} = Timeline.sync([room_id], user.id, device.id, timeout: 300, since: since)

      for {_, room_map} <- rooms, do: assert(map_size(room_map) == 0)
    end
  end

  describe "get_messages/6" do
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

    test "can successfully paginate backwards through events in a room after a sync", %{
      room_id: room_id,
      creator: %{id: creator_id} = creator,
      user: %{id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})

      {creator, device} = Fixtures.device(creator)

      %{rooms: %{join: %{^room_id => %{timeline: timeline}}}} =
        Timeline.sync([room_id], creator.id, device.id, filter: filter)

      %{
        sync: prev_batch,
        events: [
          %{type: "m.room.message"},
          %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
          %{type: "m.room.member"}
        ]
      } =
        timeline

      assert {:ok, %{chunk: chunk, state: state, start: ^prev_batch, end: next}} =
               Timeline.get_messages(room_id, creator.id, device.id, {prev_batch, :backward}, :limit, filter: filter)

      assert [%{"type" => "m.room.member", "sender" => ^creator_id}, %{"type" => "m.room.member", "sender" => ^user_id}] =
               Enum.sort(state)

      assert [
               %{type: "m.room.message", content: %{"body" => "wow"}},
               %{type: "m.room.message", content: %{"body" => "yeah"}},
               %{type: "m.room.message", content: %{"body" => "so you're just using me to test something?"}}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: next2}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :backward}, :limit, filter: filter)

      assert 1 = length(state)

      assert [
               %{type: "m.room.message", content: %{"body" => "there we go"}},
               %{type: "m.room.name", content: %{"name" => "Get Messages Pagination"}},
               %{type: "m.room.message", content: %{"body" => "wait yes I do"}}
             ] = chunk

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 30}}})

      assert {:ok, %{chunk: chunk, state: state, start: ^next2} = response} =
               Timeline.get_messages(room_id, creator.id, device.id, {next2, :backward}, :limit, filter: filter)

      refute is_map_key(response, :end)

      assert 12 = length(chunk)
      assert 2 = length(state)
    end

    test "can successfully paginate forward events in a room after a sync", %{
      room_id: room_id,
      creator: %{id: creator_id} = creator,
      user: %{id: user_id}
    } do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})
      {creator, device} = Fixtures.device(creator)

      %{rooms: %{join: %{^room_id => %{timeline: timeline}}}} =
        Timeline.sync([room_id], creator.id, device.id, filter: filter)

      %{
        sync: %PaginationToken{} = prev_batch,
        events: [
          %{type: "m.room.message"},
          %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
          %{type: "m.room.member"}
        ]
      } =
        timeline

      assert {:ok, %{chunk: chunk, state: state, start: ^prev_batch} = response} =
               Timeline.get_messages(room_id, creator.id, device.id, {prev_batch, :forward}, :limit)

      assert [%{"type" => "m.room.member", "sender" => ^creator_id}, %{"type" => "m.room.member", "sender" => ^user_id}] =
               Enum.sort(state)

      refute is_map_key(response, :end)

      assert [
               %{type: "m.room.message"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.member"}
             ] = chunk

      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "welp"})

      assert {:ok, %{chunk: chunk, state: _state, start: ^prev_batch} = response} =
               Timeline.get_messages(room_id, creator.id, device.id, {prev_batch, :forward}, :limit)

      refute is_map_key(response, :end)

      assert [
               %{type: "m.room.message"},
               %{type: "m.room.message", content: %{"body" => "I thought I was more than that to you"}},
               %{type: "m.room.member"},
               %{type: "m.room.message", content: %{"body" => "welp"}}
             ] = chunk
    end

    test "can successfully paginate forward from the beginning of a room", %{room_id: room_id, creator: creator} do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 10}}})
      {creator, device} = Fixtures.device(creator)

      {:ok, root} = EventGraph.root(room_id)
      from = PaginationToken.new(root, :forward)

      assert {:ok, %{chunk: chunk, state: state, start: ^from, end: next}} =
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
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: next2}} =
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
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next2} = response} =
               Timeline.get_messages(room_id, creator.id, device.id, {next2, :forward}, :limit, filter: filter)

      assert 1 = length(state)
      refute is_map_key(response, :end)
      [%{type: "m.room.member", content: %{"membership" => "leave"}}] = chunk
    end

    test "can successfully paginate backward from the end of a room", %{room_id: room_id, creator: creator} do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 10}}})
      {creator, device} = Fixtures.device(creator)

      {:ok, tip} = EventGraph.tip(room_id)
      from = PaginationToken.new(tip, :backward)

      assert {:ok, %{chunk: chunk, state: state, start: ^from, end: next}} =
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
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: next2}} =
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
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next2} = response} =
               Timeline.get_messages(room_id, creator.id, device.id, {next2, :backward}, :limit, filter: filter)

      assert 1 = length(state)
      refute is_map_key(response, :end)
      [%{type: "m.room.create"}] = chunk
    end

    test "can successfully paginate in either direction froma prev_batch_token", %{room_id: room_id, creator: creator} do
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 3}}})
      {creator, device} = Fixtures.device(creator)

      %{rooms: %{join: %{^room_id => %{timeline: %{sync: prev_batch}}}}} =
        Timeline.sync([room_id], creator.id, device.id, filter: filter)

      assert {:ok, %{chunk: chunk, state: state, start: ^prev_batch, end: next}} =
               Timeline.get_messages(room_id, creator.id, device.id, {prev_batch, :backward}, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "wow"}, event_id: event_id1},
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: next2}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :backward}, :limit, filter: filter)

      assert 1 = length(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}, event_id: event_id2},
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "wait yes I do"}}
             ] = chunk

      {:ok, end_page_2_pdu} = PDU.get(event_id2)
      expected_end = PaginationToken.new(end_page_2_pdu, :forward)

      assert {:ok, %{chunk: chunk, state: state, start: ^next2, end: ^expected_end}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next2, :forward}, :limit, filter: filter)

      assert 1 = length(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "wait yes I do"}},
               %{content: %{"name" => "Get Messages Pagination"}},
               %{content: %{"msgtype" => "m.text", "body" => "there we go"}}
             ] = chunk

      {:ok, end_page_1_pdu} = PDU.get(event_id1)
      expected_end = PaginationToken.new(end_page_1_pdu, :forward)

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: ^expected_end}} =
               Timeline.get_messages(room_id, creator.id, device.id, {next, :forward}, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{content: %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}},
               %{content: %{"msgtype" => "m.text", "body" => "yeah"}},
               %{content: %{"msgtype" => "m.text", "body" => "wow"}}
             ] = chunk
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

      assert {:ok, %{chunk: [_one, _two], state: state}} =
               Timeline.get_messages(room_id, user2.id, user2_device_id, :tip, :limit, filter: filter)

      for id <- [user.id, user2.id] do
        assert Enum.any?(state, &match?(%{"type" => "m.room.member", "sender" => ^id}, &1))
      end

      creator_id = creator.id
      refute Enum.any?(state, &match?(%{"type" => "m.room.member", "sender" => ^creator_id}, &1))
    end

    test "returned events have bundled aggregations", %{room_id: room_id, creator: creator} do
      {:ok, parent_id} = Fixtures.send_text_msg(room_id, creator.id, "thread start")
      rel = %{"m.relates_to" => %{"event_id" => parent_id, "rel_type" => "m.thread"}}
      {:ok, child_id} = Fixtures.send_text_msg(room_id, creator.id, "we're talkin'", rel)

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 2}}})

      {creator, creator_device_id} = Fixtures.device(creator)

      {:ok, %{chunk: chunk}} =
        Timeline.get_messages(room_id, creator.id, creator_device_id, :tip, :limit, filter: filter)

      assert [
               %{
                 event_id: ^parent_id,
                 unsigned: %{"m.relations" => %{"m.thread" => %{latest_event: %{event_id: ^child_id}}}}
               }
             ] = chunk
    end
  end

  describe "Jason.Encoder impl" do
    test "encodes a complete timeline" do
      timeline = Timeline.complete([%{event_id: "whateva"}])
      assert {:ok, ~s|{"events":[{"event_id":"whateva"}],"limited":false}|} = Jason.encode(timeline)
    end

    test "encodes a partial timeline" do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)
      {:ok, root} = EventGraph.root(room_id)
      token = PaginationToken.new(root, :backward)
      encoded_token = PaginationToken.encode(token)
      timeline = Timeline.partial([%{event_id: "whateva"}], token)

      assert {:ok, json} = Jason.encode(timeline)
      assert json =~ ~s|"events":[{"event_id":"whateva"}]|
      assert json =~ ~s|"limited":true|
      assert json =~ ~s|"prev_batch":"#{encoded_token}"|
    end
  end
end
