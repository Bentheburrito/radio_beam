defmodule RadioBeam.Room.TimelineTest do
  use ExUnit.Case, async: true

  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline
  alias RadioBeam.User

  setup do
    {:ok, creator} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
    {:ok, creator} = Repo.insert(creator)
    {:ok, user} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
    {:ok, user} = Repo.insert(user)

    %{creator: creator, user: user}
  end

  describe "sync/4 performing an initial sync" do
    test "successfully syncs all events in a newly created room", %{creator: creator, user: user} do
      {:ok, room_id1} = Room.create(creator)
      {:ok, room_id2} = Room.create(creator, name: "The Chatroom")
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: [], timeline: timeline}},
                 invite: %{^room_id2 => %{invite_state: invite_state}}
               }
             } =
               Timeline.sync([room_id1, room_id2], user.id)

      user_id = user.id

      assert %{
               limited: false,
               events: [
                 %{"type" => "m.room.create"},
                 %{"type" => "m.room.member"},
                 %{"type" => "m.room.power_levels"},
                 %{"type" => "m.room.join_rules"},
                 %{"type" => "m.room.history_visibility"},
                 %{"type" => "m.room.guest_access"},
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "invite"}},
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "join"}}
               ]
             } =
               timeline

      assert 3 = length(invite_state.events)
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.name"}, &1))

      refute is_map_key(timeline, :prev_batch)
    end

    test "successfully syncs all events up to n", %{creator: creator, user: user} do
      {:ok, room_id1} = Room.create(creator)
      {:ok, room_id2} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      filter = %{"room" => %{"timeline" => %{"limit" => 5}}}

      assert %{
               rooms: %{
                 join: %{
                   ^room_id1 => %{
                     state: state,
                     timeline: timeline
                   }
                 },
                 invite: %{^room_id2 => %{invite_state: invite_state}}
               }
             } =
               Timeline.sync([room_id1, room_id2], user.id, filter: filter)

      assert Enum.any?(state, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(state, &match?(%{"type" => "m.room.member"}, &1))
      assert %{"event_id" => pl_event_id} = Enum.find(state, &(&1["type"] == "m.room.power_levels"))

      assert %{
               limited: true,
               events: [
                 %{"type" => "m.room.join_rules"},
                 %{"type" => "m.room.history_visibility"},
                 %{"type" => "m.room.guest_access"},
                 %{"type" => "m.room.member"},
                 %{"type" => "m.room.member"}
               ],
               prev_batch: ^pl_event_id
             } =
               timeline

      assert 2 = length(invite_state.events)
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.join_rules"}, &1))
    end
  end

  describe "sync/4 performing a follow-up sync" do
    test "successfully syncs all new events when there aren't many", %{creator: creator, user: user} do
      assert %{rooms: %{}, next_batch: since} = Timeline.sync([], user.id)

      # ---

      {:ok, room_id1} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: [], timeline: timeline}},
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: since
             } =
               Timeline.sync([room_id1], user.id, since: since)

      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      user_id = user.id

      assert %{
               limited: false,
               events: [
                 %{"type" => "m.room.create"},
                 %{"type" => "m.room.member"},
                 %{"type" => "m.room.power_levels"},
                 %{"type" => "m.room.join_rules"},
                 %{"type" => "m.room.history_visibility"},
                 %{"type" => "m.room.guest_access"},
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "invite"}},
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "join"}}
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
               Timeline.sync([room_id1, room_id2], user.id, since: since)

      assert 0 = map_size(join_map)

      assert 3 = length(invite_state.events)
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.name"}, &1))

      # ---

      {:ok, rando} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
      {:ok, %{id: rando_id}} = Repo.insert(rando)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, rando_id)
      {:ok, _event_id} = Room.join(room_id1, rando_id)

      assert %{
               rooms: %{join: %{^room_id1 => %{state: [], timeline: timeline}}, invite: invite_map},
               next_batch: since
             } =
               Timeline.sync([room_id1, room_id2], user.id, since: since)

      assert 0 = map_size(invite_map)

      assert %{
               limited: false,
               events: [
                 %{"type" => "m.room.member", "state_key" => ^rando_id, "content" => %{"membership" => "invite"}},
                 %{"type" => "m.room.member", "state_key" => ^rando_id, "content" => %{"membership" => "join"}}
               ]
             } =
               timeline

      # ---

      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "should be able to see this")
      {:ok, _event_id} = Room.leave(room_id1, user.id, "byeeeeeeeeeeeeeee")
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "alright user is gone let's party!!!!!!!!")

      filter = %{"room" => %{"include_leave" => true}}

      assert %{
               rooms: %{
                 join: join_map,
                 invite: invite_map,
                 leave: %{^room_id1 => %{state: state, timeline: timeline}}
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1, room_id2], user.id, since: since, filter: filter)

      assert 0 = map_size(join_map)
      assert 0 = map_size(invite_map)

      refute state
             |> Stream.filter(&(&1["type"] == "m.room.name"))
             |> Enum.any?(&(&1["content"]["name"] =~ "let's party!"))

      creator_id = creator.id

      assert %{
               limited: false,
               events: [
                 %{
                   "type" => "m.room.name",
                   "sender" => ^creator_id,
                   "content" => %{"name" => "should be able to see this"}
                 },
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "leave"}}
               ]
             } =
               timeline
    end

    test "successfully syncs, responding with a partial timeline when necessary", %{creator: creator, user: user} do
      {:ok, room_id1} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: [], timeline: timeline}},
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: since
             } =
               Timeline.sync([room_id1], user.id)

      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      user_id = user.id

      assert %{
               limited: false,
               events: [
                 %{"type" => "m.room.create"},
                 %{"type" => "m.room.member"},
                 %{"type" => "m.room.power_levels"},
                 %{"type" => "m.room.join_rules"},
                 %{"type" => "m.room.history_visibility"},
                 %{"type" => "m.room.guest_access"},
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "invite"}},
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "join"}}
               ]
             } =
               timeline

      refute is_map_key(timeline, :prev_batch)

      # --- 

      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "Name update outside of window")
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "First name update")
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "Second name update")

      filter = %{"room" => %{"timeline" => %{"limit" => 2}}}

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: state, timeline: timeline}},
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: since
             } =
               Timeline.sync([room_id1], user.id, since: since, filter: filter)

      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      assert [%{"event_id" => name_event_id}] = state

      assert %{
               limited: true,
               events: [
                 %{"type" => "m.room.name", "content" => %{"name" => "First name update"}},
                 %{"type" => "m.room.name", "content" => %{"name" => "Second name update"}}
               ],
               prev_batch: ^name_event_id
             } =
               timeline

      # ---

      Room.set_name(room_id1, creator.id, "THIS SHOULD SHOW UP IN FULL STATE ONLY")
      Room.send(room_id1, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello? Is anyone there?"})
      Room.send(room_id1, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "HE CAN'T HIT"})

      assert %{
               rooms: %{join: %{^room_id1 => %{state: [%{"type" => "m.room.name"}], timeline: timeline}}},
               next_batch: _since
             } =
               Timeline.sync([room_id1], user.id, since: since, filter: filter)

      assert %{
               limited: true,
               events: [
                 %{"type" => "m.room.message", "content" => %{"body" => "Hello? Is anyone there?"}},
                 %{"type" => "m.room.message", "content" => %{"body" => "HE CAN'T HIT"}}
               ],
               prev_batch: _
             } =
               timeline

      assert %{
               rooms: %{join: %{^room_id1 => %{state: state, timeline: timeline}}},
               next_batch: _since
             } =
               Timeline.sync([room_id1], user.id, since: since, filter: filter, full_state?: true)

      assert 8 = length(state)

      assert %{
               limited: true,
               events: [
                 %{"type" => "m.room.message", "content" => %{"body" => "Hello? Is anyone there?"}},
                 %{"type" => "m.room.message", "content" => %{"body" => "HE CAN'T HIT"}}
               ],
               prev_batch: _
             } =
               timeline
    end
  end

  describe "sync/4 with a filter" do
    test "applies timeline- and state-specific rooms and not_rooms filters", %{creator: creator, user: user} do
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
      filter = %{"room" => %{"timeline" => event_filter, "state" => event_filter}}

      assert %{
               rooms: %{
                 join: %{^room_id2 => %{state: [], timeline: timeline}} = join_map,
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1, room_id2, room_id3], user.id, filter: filter)

      assert 1 = map_size(join_map)
      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      assert %{
               limited: false,
               events: [%{"type" => "m.room.create"} | _] = events
             } =
               timeline

      assert %{"type" => "m.room.name", "content" => %{"name" => "General Chat"}} = List.last(events)
    end

    test "applies `room`-key-level rooms and not_rooms filters", %{creator: creator, user: user} do
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

      filter = %{"room" => %{"rooms" => [room_id1, room_id2], "not_rooms" => [room_id1]}}

      assert %{
               rooms: %{
                 join: %{^room_id2 => %{state: [], timeline: timeline}} = join_map,
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1, room_id2, room_id3], user.id, filter: filter)

      assert 1 = map_size(join_map)
      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      assert %{
               limited: false,
               events: [%{"type" => "m.room.create"} | _] = events
             } =
               timeline

      assert %{"type" => "m.room.name", "content" => %{"name" => "General Chat"}} = List.last(events)
    end
  end

  describe "sync/4 with a timeout" do
    test "will wait for the next room event", %{creator: creator, user: user} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: [], timeline: timeline}}
               },
               next_batch: since
             } =
               Timeline.sync([room_id], user.id)

      user_id = user.id

      assert %{
               limited: false,
               events: [
                 %{"type" => "m.room.create"},
                 %{"type" => "m.room.member"},
                 %{"type" => "m.room.power_levels"},
                 %{"type" => "m.room.join_rules"},
                 %{"type" => "m.room.history_visibility"},
                 %{"type" => "m.room.guest_access"},
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "invite"}},
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "join"}}
               ]
             } =
               timeline

      time_before_wait = :os.system_time(:millisecond)

      sync_task =
        Task.async(fn -> Timeline.sync([room_id], user.id, timeout: 1500, since: since) end)

      Process.sleep(750)
      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello"})

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: [], timeline: timeline}}
               }
             } = Task.await(sync_task)

      assert %{
               limited: false,
               events: [%{"type" => "m.room.message"}]
             } =
               timeline

      assert :os.system_time(:millisecond) - time_before_wait >= 750
    end

    test "will wait for the next room event that matches the filter", %{creator: creator, user: user} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: [], timeline: _timeline}}
               },
               next_batch: since
             } =
               Timeline.sync([room_id], user.id)

      time_before_wait = :os.system_time(:millisecond)

      event_filter = %{"not_senders" => [creator.id]}
      filter = %{"room" => %{"timeline" => event_filter, "state" => event_filter}}

      sync_task =
        Task.async(fn -> Timeline.sync([room_id], user.id, filter: filter, timeout: 1000, since: since) end)

      Process.sleep(100)
      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello"})

      assert is_nil(Task.yield(sync_task, 0))

      Process.sleep(100)
      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello"})

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: [], timeline: timeline}}
               }
             } = Task.await(sync_task)

      assert %{
               limited: false,
               events: [%{"type" => "m.room.message"}]
             } =
               timeline

      assert :os.system_time(:millisecond) - time_before_wait >= 200
    end

    test "will timeout", %{creator: creator, user: user} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %{
               rooms: %{
                 join: %{^room_id => %{state: [], timeline: _timeline}}
               },
               next_batch: since
             } =
               Timeline.sync([room_id], user.id)

      %{rooms: rooms} = Timeline.sync([room_id], user.id, timeout: 300, since: since)

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
      filter = %{"room" => %{"timeline" => %{"limit" => 3}}}

      %{rooms: %{join: %{^room_id => %{timeline: timeline}}}} = Timeline.sync([room_id], creator.id, filter: filter)

      %{
        limited: true,
        events: [
          %{"type" => "m.room.message"},
          %{"type" => "m.room.message", "content" => %{"body" => "I thought I was more than that to you"}},
          %{"type" => "m.room.member"}
        ],
        prev_batch: prev_batch
      } =
        timeline

      assert {:ok, %{chunk: chunk, state: state, start: ^prev_batch, end: next}} =
               Timeline.get_messages(room_id, creator.id, :backward, prev_batch, :limit, filter: filter)

      assert [%{"type" => "m.room.member", "sender" => ^creator_id}, %{"type" => "m.room.member", "sender" => ^user_id}] =
               Enum.sort(state)

      assert [
               %{"type" => "m.room.message", "content" => %{"body" => "wow"}},
               %{"type" => "m.room.message", "content" => %{"body" => "yeah"}},
               %{"type" => "m.room.message", "content" => %{"body" => "so you're just using me to test something?"}}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: next2}} =
               Timeline.get_messages(room_id, creator.id, :backward, next, :limit, filter: filter)

      assert 1 = length(state)

      assert [
               %{"type" => "m.room.message", "content" => %{"body" => "there we go"}},
               %{"type" => "m.room.name", "content" => %{"name" => "Get Messages Pagination"}},
               %{"type" => "m.room.message", "content" => %{"body" => "wait yes I do"}}
             ] = chunk

      filter = %{"room" => %{"timeline" => %{"limit" => 30}}}

      assert {:ok, %{chunk: chunk, state: state, start: ^next2} = response} =
               Timeline.get_messages(room_id, creator.id, :backward, next2, :limit, filter: filter)

      refute is_map_key(response, :end)

      assert 12 = length(chunk)
      assert 2 = length(state)
    end

    test "can successfully paginate forward events in a room after a sync", %{
      room_id: room_id,
      creator: %{id: creator_id} = creator,
      user: %{id: user_id}
    } do
      filter = %{"room" => %{"timeline" => %{"limit" => 3}}}
      %{rooms: %{join: %{^room_id => %{timeline: timeline}}}} = Timeline.sync([room_id], creator.id, filter: filter)

      %{
        limited: true,
        events: [
          %{"type" => "m.room.message"},
          %{"type" => "m.room.message", "content" => %{"body" => "I thought I was more than that to you"}},
          %{"type" => "m.room.member"}
        ],
        prev_batch: prev_batch
      } =
        timeline

      assert {:ok, %{chunk: chunk, state: state, start: ^prev_batch} = response} =
               Timeline.get_messages(room_id, creator.id, :forward, prev_batch, :limit)

      assert [%{"type" => "m.room.member", "sender" => ^creator_id}, %{"type" => "m.room.member", "sender" => ^user_id}] =
               Enum.sort(state)

      refute is_map_key(response, :end)

      assert [
               %{"type" => "m.room.message"},
               %{"type" => "m.room.message", "content" => %{"body" => "I thought I was more than that to you"}},
               %{"type" => "m.room.member"}
             ] = chunk

      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "welp"})

      assert {:ok, %{chunk: chunk, state: _state, start: ^prev_batch} = response} =
               Timeline.get_messages(room_id, creator.id, :forward, prev_batch, :limit)

      refute is_map_key(response, :end)

      assert [
               %{"type" => "m.room.message"},
               %{"type" => "m.room.message", "content" => %{"body" => "I thought I was more than that to you"}},
               %{"type" => "m.room.member"},
               %{"type" => "m.room.message", "content" => %{"body" => "welp"}}
             ] = chunk
    end

    test "can successfully paginate forward from the beginning of a room", %{room_id: room_id, creator: creator} do
      filter = %{"room" => %{"timeline" => %{"limit" => 10}}}

      assert {:ok, %{chunk: chunk, state: state, start: :first, end: next}} =
               Timeline.get_messages(room_id, creator.id, :forward, :first, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{"type" => "m.room.create"},
               %{"type" => "m.room.member"},
               %{"type" => "m.room.power_levels"},
               %{"type" => "m.room.join_rules"},
               %{"type" => "m.room.history_visibility"},
               %{"type" => "m.room.guest_access"},
               %{"type" => "m.room.member", "content" => %{"membership" => "invite"}},
               %{"type" => "m.room.member", "content" => %{"membership" => "join"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "sup"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "yo"}}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: next2}} =
               Timeline.get_messages(room_id, creator.id, :forward, next, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{"content" => %{"msgtype" => "m.text", "body" => "what is this room about"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "idk"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "wait yes I do"}},
               %{"content" => %{"name" => "Get Messages Pagination"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "there we go"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "yeah"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "wow"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "?"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "I thought I was more than that to you"}}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next2} = response} =
               Timeline.get_messages(room_id, creator.id, :forward, next2, :limit, filter: filter)

      assert 1 = length(state)
      refute is_map_key(response, :end)
      [%{"type" => "m.room.member", "content" => %{"membership" => "leave"}}] = chunk
    end

    test "can successfully paginate backward from the end of a room", %{room_id: room_id, creator: creator} do
      filter = %{"room" => %{"timeline" => %{"limit" => 10}}}

      assert {:ok, %{chunk: chunk, state: state, start: :last, end: next}} =
               Timeline.get_messages(room_id, creator.id, :backward, :last, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{"type" => "m.room.member", "content" => %{"membership" => "leave"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "I thought I was more than that to you"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "?"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "wow"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "yeah"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "there we go"}},
               %{"content" => %{"name" => "Get Messages Pagination"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "wait yes I do"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "idk"}}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: next2}} =
               Timeline.get_messages(room_id, creator.id, :backward, next, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{"content" => %{"msgtype" => "m.text", "body" => "what is this room about"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "yo"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "sup"}},
               %{"type" => "m.room.member", "content" => %{"membership" => "join"}},
               %{"type" => "m.room.member", "content" => %{"membership" => "invite"}},
               %{"type" => "m.room.guest_access"},
               %{"type" => "m.room.history_visibility"},
               %{"type" => "m.room.join_rules"},
               %{"type" => "m.room.power_levels"},
               %{"type" => "m.room.member"}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next2} = response} =
               Timeline.get_messages(room_id, creator.id, :backward, next2, :limit, filter: filter)

      assert 1 = length(state)
      refute is_map_key(response, :end)
      [%{"type" => "m.room.create"}] = chunk
    end

    test "can successfully paginate in either direction froma prev_batch_token", %{room_id: room_id, creator: creator} do
      filter = %{"room" => %{"timeline" => %{"limit" => 3}}}

      %{rooms: %{join: %{^room_id => %{timeline: %{prev_batch: prev_batch}}}}} =
        Timeline.sync([room_id], creator.id, filter: filter)

      assert {:ok, %{chunk: chunk, state: state, start: ^prev_batch, end: next}} =
               Timeline.get_messages(room_id, creator.id, :backward, prev_batch, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{"content" => %{"msgtype" => "m.text", "body" => "wow"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "yeah"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: next2}} =
               Timeline.get_messages(room_id, creator.id, :backward, next, :limit, filter: filter)

      assert 1 = length(state)

      assert [
               %{"content" => %{"msgtype" => "m.text", "body" => "there we go"}},
               %{"content" => %{"name" => "Get Messages Pagination"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "wait yes I do"}}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next2, end: ^next}} =
               Timeline.get_messages(room_id, creator.id, :forward, next2, :limit, filter: filter)

      assert 1 = length(state)

      assert [
               %{"content" => %{"msgtype" => "m.text", "body" => "wait yes I do"}},
               %{"content" => %{"name" => "Get Messages Pagination"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "there we go"}}
             ] = chunk

      assert {:ok, %{chunk: chunk, state: state, start: ^next, end: ^prev_batch}} =
               Timeline.get_messages(room_id, creator.id, :forward, next, :limit, filter: filter)

      assert 2 = length(state)

      assert [
               %{"content" => %{"msgtype" => "m.text", "body" => "so you're just using me to test something?"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "yeah"}},
               %{"content" => %{"msgtype" => "m.text", "body" => "wow"}}
             ] = chunk
    end
  end
end
