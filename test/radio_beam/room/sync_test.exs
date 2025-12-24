defmodule RadioBeam.Room.SyncTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.Events.PaginationToken
  alias RadioBeam.Room.Sync
  alias RadioBeam.Room.Sync.InvitedRoomResult
  alias RadioBeam.Room.Sync.JoinedRoomResult
  alias RadioBeam.User.EventFilter

  setup do
    creator = Fixtures.user()
    {user, device} = Fixtures.device(Fixtures.user())

    %{creator: creator, user: user, device: device}
  end

  describe "performing an initial sync" do
    test "successfully syncs all events in a newly created room", %{creator: creator, user: user, device: device} do
      {:ok, room_id1} = Room.create(creator)
      {:ok, room_id2} = Room.create(creator, name: "The Chatroom")
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user |> Sync.init(device.id) |> Sync.perform()

      assert 2 = map_size(next_batch_map)
      join_next_batch_event_id = Map.fetch!(next_batch_map, room_id1)

      assert [%{id: ^join_next_batch_event_id}] =
               room_id1 |> Room.View.timeline_event_stream!(user.id, :tip) |> Enum.take(1)

      user_id = user.id

      # user shouldn't be able to see even their own invited membership event.
      # only the stripped state event can be viewed
      assert {:error, :unauthorized} = Room.get_state(room_id2, user.id, "m.room.member", user_id)
      {:ok, %{id: invite_next_batch_event_id}} = Room.get_state(room_id2, creator.id, "m.room.member", user_id)

      assert ^invite_next_batch_event_id = Map.fetch!(next_batch_map, room_id2)

      assert [
               %InvitedRoomResult{room_id: ^room_id2, stripped_state_events: invite_state_stream},
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: :no_more_events
               }
             ] = Enum.sort(result_data)

      assert [] = Enum.to_list(state_event_stream)

      assert [
               %{type: "m.room.create"},
               %{type: "m.room.member"},
               %{type: "m.room.power_levels"},
               %{type: "m.room.join_rules"},
               %{type: "m.room.history_visibility"},
               %{type: "m.room.guest_access"},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
             ] =
               events

      invite_state = Enum.to_list(invite_state_stream)
      assert 4 = length(invite_state)
      assert Enum.any?(invite_state, &match?(%{type: "m.room.create"}, &1))
      assert Enum.any?(invite_state, &match?(%{type: "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state, &match?(%{type: "m.room.name"}, &1))
      assert Enum.any?(invite_state, &match?(%{type: "m.room.member", state_key: ^user_id}, &1))
    end

    test "successfully syncs, bundling aggregate events", %{creator: creator, user: user, device: device} do
      {:ok, room_id1} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      {:ok, thread_id} = Room.send_text_message(room_id1, user.id, "I have news -> 🧵")

      content = %{
        "msgtype" => "m.text",
        "content" => "it's @bob's birthday!!!!!!!!",
        "m.relates_to" => %{"event_id" => thread_id, "rel_type" => "m.thread"}
      }

      Room.send(room_id1, user.id, "m.room.message", content)
      # Process.sleep(1)

      {:ok, latest_event_id} =
        Room.send(room_id1, creator.id, "m.room.message", put_in(content["content"], "happy bday @bob!!!!!"))

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user |> Sync.init(device.id) |> Sync.perform()

      assert 1 = map_size(next_batch_map)
      join_next_batch_event_id = Map.fetch!(next_batch_map, room_id1)

      assert [%{id: ^join_next_batch_event_id}] =
               room_id1 |> Room.View.timeline_event_stream!(user.id, :tip) |> Enum.take(1)

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: :no_more_events
               }
             ] = Enum.sort(result_data)

      assert [] = Enum.to_list(state_event_stream)

      user_id = user.id

      assert [
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
                 bundled_events: [
                   %{type: "m.room.message", content: %{"content" => "happy bday @bob!!!!!"}, id: ^latest_event_id},
                   %{type: "m.room.message", content: %{"content" => "it's @bob's birthday!!!!!!!!"}}
                 ]
               }
             ] =
               events
    end

    test "successfully syncs all events up to n", %{creator: creator, user: user, device: device} do
      {:ok, room_id1} = Room.create(creator)
      {:ok, room_id2} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 5}}})

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user |> Sync.init(device.id, filter: filter) |> Sync.perform()

      assert 2 = map_size(next_batch_map)

      user_id = user.id

      # user shouldn't be able to see even their own invited membership event.
      # only the stripped state event can be viewed
      assert {:error, :unauthorized} = Room.get_state(room_id2, user.id, "m.room.member", user_id)

      {:ok, %{id: invite_next_batch_event_id}} =
        Room.get_state(room_id2, creator.id, "m.room.member", user_id)

      assert ^invite_next_batch_event_id = Map.fetch!(next_batch_map, room_id2)

      join_next_batch_event_id = Map.fetch!(next_batch_map, room_id1)

      assert [%{id: ^join_next_batch_event_id}] =
               room_id1 |> Room.View.timeline_event_stream!(user.id, :tip) |> Enum.take(1)

      assert [
               %InvitedRoomResult{room_id: ^room_id2, stripped_state_events: invite_state_stream},
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: next_event_id
               }
             ] = Enum.sort(result_data)

      state = Enum.to_list(state_event_stream)

      assert Enum.any?(state, &match?(%{type: "m.room.create"}, &1))
      assert Enum.any?(state, &match?(%{type: "m.room.member"}, &1))
      assert Enum.any?(state, &match?(%{type: "m.room.power_levels"}, &1))

      assert [
               %{type: "m.room.join_rules", id: event_id},
               %{type: "m.room.history_visibility"},
               %{type: "m.room.guest_access"},
               %{type: "m.room.member"},
               %{type: "m.room.member"}
             ] =
               events

      refute :no_more_events == next_event_id
      assert event_id == next_event_id

      invite_state = Enum.to_list(invite_state_stream)
      assert 3 = length(invite_state)
      assert Enum.any?(invite_state, &match?(%{type: "m.room.create"}, &1))
      assert Enum.any?(invite_state, &match?(%{type: "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state, &match?(%{type: "m.room.member", state_key: ^user_id}, &1))
    end

    test "successfully syncs, filtering out timeline events from ignored users", %{
      creator: creator,
      user: user,
      device: device
    } do
      annoying_user = Fixtures.user()

      {:ok, user} =
        RadioBeam.User.Account.put(user.id, :global, "m.ignored_user_list", %{
          "ignored_users" => %{annoying_user.id => %{}}
        })

      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)
      {:ok, _event_id} = Room.invite(room_id, creator.id, annoying_user.id)
      {:ok, _event_id} = Room.join(room_id, annoying_user.id)

      Room.send_text_message(room_id, annoying_user.id, "blah blah blah")
      Room.send_text_message(room_id, annoying_user.id, "you shouldn't see this")

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user |> Sync.init(device.id) |> Sync.perform()

      assert [%JoinedRoomResult{room_id: ^room_id, timeline_events: events}] = result_data

      annoying_user_id = annoying_user.id
      refute Enum.any?(events, &match?(%{sender: ^annoying_user_id, state_key: nil}, &1))

      {:ok, _event_id} = Room.leave(room_id, annoying_user.id)
      Room.send_text_message(room_id, creator.id, "welp, bye")

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 1}}})

      assert %Sync.Result{data: result_data} =
               user
               |> Sync.init(device.id,
                 filter: filter,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()

      assert [%JoinedRoomResult{room_id: ^room_id, state_events: state_events}] = result_data

      assert Enum.any?(state_events, &match?(%{sender: ^annoying_user_id}, &1))
    end

    test "successfully syncs, filtering out invites from ignored users", %{user: user, device: device} do
      annoying_user = Fixtures.user()

      {:ok, user} =
        RadioBeam.User.Account.put(user.id, :global, "m.ignored_user_list", %{
          "ignored_users" => %{annoying_user.id => %{}}
        })

      {:ok, room_id} = Room.create(annoying_user)
      {:ok, _event_id} = Room.invite(room_id, annoying_user.id, user.id)

      assert %Sync.Result{data: [], next_batch_map: next_batch_map} =
               user |> Sync.init(device.id) |> Sync.perform()

      {:ok, user} = RadioBeam.User.Account.put(user.id, :global, "m.ignored_user_list", %{"ignored_users" => %{}})

      assert %Sync.Result{data: [%InvitedRoomResult{room_id: ^room_id}]} =
               user
               |> Sync.init(device.id,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()

      assert %Sync.Result{data: [%InvitedRoomResult{room_id: ^room_id}]} =
               user |> Sync.init(device.id) |> Sync.perform()
    end
  end

  describe "sync/4 performing a follow-up sync" do
    test "successfully syncs all new events when there aren't many", %{creator: creator, user: user, device: device} do
      assert %Sync.Result{next_batch_map: next_batch_map} =
               user |> Sync.init(device.id) |> Sync.perform()

      # ---

      {:ok, room_id1} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user
               |> Sync.init(device.id,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 timeline_events: events,
                 state_events: state_event_stream,
                 maybe_next_event_id: :no_more_events
               }
             ] = result_data

      assert [] = Enum.to_list(state_event_stream)

      user_id = user.id

      assert [
               %{type: "m.room.create"},
               %{type: "m.room.member"},
               %{type: "m.room.power_levels"},
               %{type: "m.room.join_rules"},
               %{type: "m.room.history_visibility"},
               %{type: "m.room.guest_access"},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
             ] =
               events

      # ---

      {:ok, room_id2} = Room.create(creator, name: "Notes")
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user
               |> Sync.init(device.id,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()

      assert [%InvitedRoomResult{room_id: ^room_id2, stripped_state_events: invite_state_stream}] =
               Enum.sort(result_data)

      # assert 0 = map_size(join_map)

      user_id = user.id

      invite_state = Enum.to_list(invite_state_stream)
      assert 4 = length(invite_state)
      assert Enum.any?(invite_state, &match?(%{type: "m.room.create"}, &1))
      assert Enum.any?(invite_state, &match?(%{type: "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state, &match?(%{type: "m.room.name"}, &1))
      assert Enum.any?(invite_state, &match?(%{type: "m.room.member", state_key: ^user_id}, &1))

      # ---

      %{id: rando_id} = Fixtures.user()
      {:ok, _event_id} = Room.invite(room_id1, creator.id, rando_id)
      {:ok, _event_id} = Room.join(room_id1, rando_id)

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user
               |> Sync.init(device.id,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()

      assert [%JoinedRoomResult{room_id: ^room_id1, state_events: state_event_stream, timeline_events: events}] =
               result_data

      assert [] = Enum.to_list(state_event_stream)

      assert [
               %{type: "m.room.member", state_key: ^rando_id, content: %{"membership" => "invite"}},
               %{type: "m.room.member", state_key: ^rando_id, content: %{"membership" => "join"}}
             ] = events

      # ---

      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "should be able to see this")
      {:ok, _event_id} = Room.leave(room_id1, user.id, "byeeeeeeeeeeeeeee")
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "alright user is gone let's party!!!!!!!!")

      filter = EventFilter.new(%{"room" => %{"include_leave" => true}})

      assert %Sync.Result{data: result_data} =
               user
               |> Sync.init(device.id,
                 filter: filter,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: events,
                 current_membership: "leave"
               }
             ] = result_data

      refute state_event_stream
             |> Stream.filter(&(&1.type == "m.room.name"))
             |> Enum.any?(&(&1.content["name"] =~ "let's party!"))

      creator_id = creator.id

      assert [
               %{type: "m.room.name", sender: ^creator_id, content: %{"name" => "should be able to see this"}},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "leave"}}
             ] =
               events
    end

    test "successfully syncs, responding with a partial timeline when necessary", %{
      creator: creator,
      user: user,
      device: device
    } do
      {:ok, room_id1} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id1, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id1, user.id)

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user
               |> Sync.init(device.id)
               |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: :no_more_events
               }
             ] =
               result_data

      assert [] = Enum.to_list(state_event_stream)

      user_id = user.id

      assert [
               %{type: "m.room.create"},
               %{type: "m.room.member"},
               %{type: "m.room.power_levels"},
               %{type: "m.room.join_rules"},
               %{type: "m.room.history_visibility"},
               %{type: "m.room.guest_access"},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
             ] =
               events

      # --- 

      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "Name update outside of window")
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "First name update")
      {:ok, _event_id} = Room.set_name(room_id1, creator.id, "Second name update")

      filter = EventFilter.new(%{"room" => %{"timeline" => %{"limit" => 2}}})

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user
               |> Sync.init(device.id,
                 filter: filter,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: next_event_id
               }
             ] =
               result_data

      assert [%{type: "m.room.name"}] = Enum.to_list(state_event_stream)

      assert [
               %{type: "m.room.name", content: %{"name" => "First name update"}, id: event_id},
               %{type: "m.room.name", content: %{"name" => "Second name update"}}
             ] =
               events

      refute next_event_id == :no_more_events
      assert next_event_id == event_id
      # ---

      Room.set_name(room_id1, creator.id, "THIS SHOULD SHOW UP IN FULL STATE ONLY")
      Room.send(room_id1, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello? Is anyone there?"})
      Room.send(room_id1, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "HE CAN'T HIT"})

      assert %Sync.Result{data: result_data} =
               user
               |> Sync.init(device.id,
                 filter: filter,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: "$" <> _
               }
             ] =
               result_data

      assert [%{type: "m.room.name"}] = Enum.to_list(state_event_stream)

      assert [
               %{type: "m.room.message", content: %{"body" => "Hello? Is anyone there?"}},
               %{type: "m.room.message", content: %{"body" => "HE CAN'T HIT"}}
             ] =
               events

      assert %Sync.Result{data: result_data} =
               user
               |> Sync.init(device.id,
                 filter: filter,
                 full_state?: true,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: "$" <> _
               }
             ] =
               result_data

      assert 8 = Enum.count(state_event_stream)

      assert [
               %{type: "m.room.message", content: %{"body" => "Hello? Is anyone there?"}},
               %{type: "m.room.message", content: %{"body" => "HE CAN'T HIT"}}
             ] =
               events
    end
  end

  describe "sync/4 with a filter" do
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

      assert %Sync.Result{data: result_data} = user |> Sync.init(device.id, filter: filter) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id2,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: :no_more_events
               }
             ] =
               result_data

      assert 0 = Enum.count(state_event_stream)

      assert [%{type: "m.room.create"} | _] = events

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

      {:ok, _event_id} = Room.send_text_message(room_id1, creator.id, "welcome all")
      {:ok, _event_id} = Room.send_text_message(room_id1, user.id, "hello!")
      {:ok, _event_id} = Room.send_text_message(room_id1, user2.id, "hi")
      {:ok, _event_id} = Room.send_text_message(room_id1, user3.id, "yo")

      filter = EventFilter.new(%{"room" => %{"state" => %{"lazy_load_members" => true}, "timeline" => %{"limit" => 2}}})
      {user3, %{id: user3_device_id}} = Fixtures.device(user3)

      assert %Sync.Result{data: result_data} = user3 |> Sync.init(user3_device_id, filter: filter) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: [_one, _two],
                 maybe_next_event_id: "$" <> _
               }
             ] =
               result_data

      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user.id))

      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user2.id))
      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user3.id))

      # the creator's membership event should always be present

      {creator, %{id: creator_device_id}} = Fixtures.device(creator)

      assert %Sync.Result{data: result_data} = creator |> Sync.init(creator_device_id, filter: filter) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: [_one, _two],
                 maybe_next_event_id: "$" <> _
               }
             ] =
               result_data

      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user.id))
      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user2.id))
      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user3.id))
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

      {:ok, _event_id} = Room.send_text_message(room_id1, creator.id, "welcome all")
      {:ok, _event_id} = Room.send_text_message(room_id1, user.id, "hello!")
      {:ok, _event_id} = Room.send_text_message(room_id1, user2.id, "hi")
      {:ok, _event_id} = Room.send_text_message(room_id1, user3.id, "yo")

      filter = EventFilter.new(%{"room" => %{"state" => %{"lazy_load_members" => true}, "timeline" => %{"limit" => 2}}})
      {user, device} = Fixtures.device(user)

      assert %Sync.Result{data: result_data} = user3 |> Sync.init(device.id, filter: filter) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: [_one, _two],
                 maybe_next_event_id: "$" <> _
               }
             ] =
               result_data

      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user.id))

      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user2.id))
      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user3.id))

      # initial sync again - memberships already sent last time should not be 
      # sent again (unless its the syncing user's membership)

      {:ok, _event_id} = Room.send_text_message(room_id1, user2.id, "so what is the plan")
      {:ok, _event_id} = Room.send_text_message(room_id1, user.id, "brunch tomorrow @ 11")

      assert %Sync.Result{data: result_data} = user3 |> Sync.init(device.id, filter: filter) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: [_one, _two],
                 maybe_next_event_id: "$" <> _
               }
             ] =
               result_data

      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user2.id))

      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user.id))
      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user3.id))

      # adjust filter to request redundant memberships

      redundant_filter =
        EventFilter.new(%{
          "room" => %{
            "state" => %{"lazy_load_members" => true, "include_redundant_members" => true},
            "timeline" => %{"limit" => 2}
          }
        })

      assert %Sync.Result{data: result_data} = user3 |> Sync.init(device.id, filter: redundant_filter) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: [_one, _two],
                 maybe_next_event_id: "$" <> _
               }
             ] =
               result_data

      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == creator.id))

      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user.id))
      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user2.id))
      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user3.id))

      # and once more without redundant members...should only be the syncing user
      assert %Sync.Result{data: result_data} = user3 |> Sync.init(device.id, filter: filter) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id1,
                 state_events: state_event_stream,
                 timeline_events: [_one, _two],
                 maybe_next_event_id: "$" <> _
               }
             ] =
               result_data

      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == creator.id))
      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user.id))
      refute Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user2.id))

      assert Enum.find(state_event_stream, &(&1.type == "m.room.member" and &1.state_key == user3.id))
    end
  end

  describe "sync/4 with a timeout" do
    test "will wait for the next room event", %{creator: creator, user: user, device: device} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user |> Sync.init(device.id) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: :no_more_events
               }
             ] = result_data

      assert 0 = Enum.count(state_event_stream)

      user_id = user.id

      assert [
               %{type: "m.room.create"},
               %{type: "m.room.member"},
               %{type: "m.room.power_levels"},
               %{type: "m.room.join_rules"},
               %{type: "m.room.history_visibility"},
               %{type: "m.room.guest_access"},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
             ] = events

      timeout = 800
      wait_for = div(timeout, 2)
      time_before_wait = System.os_time(:millisecond)

      sync_task =
        Task.async(fn ->
          user
          |> Sync.init(device.id,
            timeout: timeout,
            since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
          )
          |> Sync.perform()
        end)

      Process.sleep(wait_for)
      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello!!"})

      assert %Sync.Result{
               data: [
                 %JoinedRoomResult{
                   room_id: ^room_id,
                   state_events: state_event_stream,
                   timeline_events: [%{type: "m.room.message"}],
                   maybe_next_event_id: :no_more_events
                 }
               ]
             } = Task.await(sync_task)

      assert 0 = Enum.count(state_event_stream)

      assert System.os_time(:millisecond) - time_before_wait >= wait_for
    end

    test "will wait for the next invite event", %{creator: creator, user: user, device: device} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user |> Sync.init(device.id) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id,
                 state_events: state_event_stream,
                 timeline_events: events,
                 maybe_next_event_id: :no_more_events
               }
             ] = result_data

      assert 0 = Enum.count(state_event_stream)

      user_id = user.id

      assert [
               %{type: "m.room.create"},
               %{type: "m.room.member"},
               %{type: "m.room.power_levels"},
               %{type: "m.room.join_rules"},
               %{type: "m.room.history_visibility"},
               %{type: "m.room.guest_access"},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "invite"}},
               %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "join"}}
             ] = events

      timeout = 800
      wait_for = div(timeout, 2)
      time_before_wait = System.os_time(:millisecond)

      sync_task =
        Task.async(fn ->
          user
          |> Sync.init(device.id,
            timeout: timeout,
            since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
          )
          |> Sync.perform()
        end)

      Process.sleep(wait_for)
      {:ok, room_id2} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id2, creator.id, user.id)

      assert %Sync.Result{
               data: [%InvitedRoomResult{room_id: ^room_id2, stripped_state_events: _events}]
             } = Task.await(sync_task)

      assert System.os_time(:millisecond) - time_before_wait >= wait_for
    end

    test "will wait for the next room event that matches the filter", %{creator: creator, user: user, device: device} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user |> Sync.init(device.id) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id,
                 state_events: state_event_stream,
                 timeline_events: _events,
                 maybe_next_event_id: :no_more_events
               }
             ] = result_data

      assert 0 = Enum.count(state_event_stream)

      time_before_wait = System.os_time(:millisecond)

      event_filter = %{"not_senders" => [creator.id]}
      filter = EventFilter.new(%{"room" => %{"timeline" => event_filter, "state" => event_filter}})

      sync_task =
        Task.async(fn ->
          user
          |> Sync.init(device.id,
            filter: filter,
            timeout: 1000,
            since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
          )
          |> Sync.perform()
        end)

      Process.sleep(100)

      Room.send(room_id, creator.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello"})

      assert is_nil(Task.yield(sync_task, 0))

      Process.sleep(100)

      Room.send(room_id, user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "Hello"})

      assert %Sync.Result{
               data: [
                 %JoinedRoomResult{
                   room_id: ^room_id,
                   state_events: state_event_stream,
                   timeline_events: events,
                   maybe_next_event_id: :no_more_events
                 }
               ]
             } = Task.await(sync_task)

      assert 0 = Enum.count(state_event_stream)

      assert [%{type: "m.room.message"}] = events

      assert System.os_time(:millisecond) - time_before_wait >= 200
    end

    test "will timeout", %{creator: creator, user: user, device: device} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      assert %Sync.Result{data: result_data, next_batch_map: next_batch_map} =
               user |> Sync.init(device.id) |> Sync.perform()

      assert [
               %JoinedRoomResult{
                 room_id: ^room_id,
                 state_events: state_event_stream,
                 timeline_events: _events,
                 maybe_next_event_id: :no_more_events
               }
             ] = result_data

      assert 0 = Enum.count(state_event_stream)

      assert %Sync.Result{data: []} =
               user
               |> Sync.init(device.id,
                 timeout: 300,
                 since: PaginationToken.new(next_batch_map, :forward, System.os_time(:millisecond))
               )
               |> Sync.perform()
    end
  end
end
