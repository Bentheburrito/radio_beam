defmodule RadioBeam.Room.TimelineTest do
  use ExUnit.Case

  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline
  alias RadioBeam.User

  describe "sync/4 performing an initial sync" do
    setup do
      {:ok, creator} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
      {:ok, creator} = Repo.insert(creator)
      {:ok, user} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
      {:ok, user} = Repo.insert(user)

      %{creator: creator, user: user}
    end

    test "successfully syncs all events in a newly created room", %{creator: creator, user: user} do
      {:ok, room_id1} = Room.create("5", creator)
      {:ok, room_id2} = Room.create("5", creator, %{}, name: "The Chatroom")
      :ok = Room.invite(room_id1, creator.id, user.id)
      :ok = Room.invite(room_id2, creator.id, user.id)
      :ok = Room.join(room_id1, user.id)

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

      assert 3 = length(invite_state.events)
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.join_rules"}, &1))
      assert Enum.any?(invite_state.events, &match?(%{"type" => "m.room.name"}, &1))

      refute is_map_key(timeline, :prev_batch)
    end

    test "successfully syncs all events up to n", %{creator: creator, user: user} do
      {:ok, room_id1} = Room.create("5", creator)
      {:ok, room_id2} = Room.create("5", creator)
      :ok = Room.invite(room_id1, creator.id, user.id)
      :ok = Room.invite(room_id2, creator.id, user.id)
      :ok = Room.join(room_id1, user.id)

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
               Timeline.sync([room_id1, room_id2], user.id, max_events: 5)

      assert Enum.any?(state, &match?(%{"type" => "m.room.create"}, &1))
      assert Enum.any?(state, &match?(%{"type" => "m.room.member"}, &1))
      assert %{"event_id" => pl_event_id} = Enum.find(state, &(&1["type"] == "m.room.power_levels"))

      assert %{
               limited: true,
               events: [
                 %{type: "m.room.join_rules"},
                 %{type: "m.room.history_visibility"},
                 %{type: "m.room.guest_access"},
                 %{type: "m.room.member"},
                 %{type: "m.room.member"}
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
    setup do
      {:ok, creator} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
      {:ok, creator} = Repo.insert(creator)
      {:ok, user} = "localhost" |> UserIdentifier.generate() |> to_string() |> User.new("Asdf123$")
      {:ok, user} = Repo.insert(user)

      %{creator: creator, user: user}
    end

    test "successfully syncs all new events when there aren't many", %{creator: creator, user: user} do
      assert %{rooms: %{}, next_batch: since} = Timeline.sync([], user.id)

      # ---

      {:ok, room_id1} = Room.create("5", creator)
      :ok = Room.invite(room_id1, creator.id, user.id)
      :ok = Room.join(room_id1, user.id)

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

      {:ok, room_id2} = Room.create("5", creator, %{}, name: "Notes")
      :ok = Room.invite(room_id2, creator.id, user.id)

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
      :ok = Room.invite(room_id1, creator.id, rando_id)
      :ok = Room.join(room_id1, rando_id)

      assert %{
               rooms: %{join: %{^room_id1 => %{state: state, timeline: timeline}}, invite: invite_map},
               next_batch: since
             } =
               Timeline.sync([room_id1, room_id2], user.id, since: since)

      assert 0 = map_size(invite_map)
      assert 7 = length(state)
      assert Enum.any?(state, &match?(%{"type" => "m.room.create"}, &1))

      assert Enum.any?(
               state,
               &match?(
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "join"}},
                 &1
               )
             )

      assert %{
               limited: false,
               events: [
                 %{type: "m.room.member", state_key: ^rando_id, content: %{"membership" => "invite"}},
                 %{type: "m.room.member", state_key: ^rando_id, content: %{"membership" => "join"}}
               ]
             } =
               timeline

      # ---

      :ok = Room.set_name(room_id1, creator.id, "should be able to see this")
      :ok = Room.leave(room_id1, user.id, "byeeeeeeeeeeeeeee")
      :ok = Room.set_name(room_id1, creator.id, "alright user is gone let's party!!!!!!!!")

      assert %{
               rooms: %{
                 join: join_map,
                 invite: invite_map,
                 leave: %{^room_id1 => %{state: state, timeline: timeline}}
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1, room_id2], user.id, since: since)

      assert 0 = map_size(join_map)
      assert 0 = map_size(invite_map)

      refute state
             |> Stream.filter(&(&1["type"] == "m.room.name"))
             |> Enum.any?(&(&1["content"]["name"] =~ "let's party!"))

      creator_id = creator.id

      assert %{
               limited: false,
               events: [
                 %{type: "m.room.name", sender: ^creator_id, content: %{"name" => "should be able to see this"}},
                 %{type: "m.room.member", state_key: ^user_id, content: %{"membership" => "leave"}}
               ]
             } =
               timeline
    end

    test "successfully syncs, responding with a partial timeline when necessary", %{creator: creator, user: user} do
      {:ok, room_id1} = Room.create("5", creator)
      :ok = Room.invite(room_id1, creator.id, user.id)
      :ok = Room.join(room_id1, user.id)

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

      :ok = Room.set_name(room_id1, creator.id, "Name update outside of window")
      :ok = Room.set_name(room_id1, creator.id, "First name update")
      :ok = Room.set_name(room_id1, creator.id, "Second name update")

      assert %{
               rooms: %{
                 join: %{^room_id1 => %{state: state, timeline: timeline}},
                 invite: invite_map,
                 leave: leave_map
               },
               next_batch: _since
             } =
               Timeline.sync([room_id1], user.id, since: since, max_events: 2)

      assert 0 = map_size(invite_map)
      assert 0 = map_size(leave_map)

      assert 8 = length(state)
      assert Enum.any?(state, &match?(%{"type" => "m.room.create"}, &1))

      assert Enum.any?(
               state,
               &match?(
                 %{"type" => "m.room.member", "state_key" => ^user_id, "content" => %{"membership" => "join"}},
                 &1
               )
             )

      assert %{"event_id" => name_event_id} = Enum.find(state, &(&1["type"] == "m.room.name"))

      assert %{
               limited: true,
               events: [
                 %{type: "m.room.name", content: %{"name" => "First name update"}},
                 %{type: "m.room.name", content: %{"name" => "Second name update"}}
               ],
               prev_batch: ^name_event_id
             } =
               timeline
    end
  end

  # TODO: full_state and timeout tests
end
