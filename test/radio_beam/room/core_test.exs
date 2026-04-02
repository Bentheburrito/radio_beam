defmodule RadioBeam.Room.CoreTest do
  use ExUnit.Case,
    async: true,
    parameterize:
      for(
        chronicle_backend <- [RadioBeam.Room.Chronicle.Map],
        dag_backend <- [RadioBeam.DAG.Map],
        room_version <-
          :radio_beam |> Application.compile_env!([:capabilities, :"m.room_versions", :available]) |> Map.keys(),
        do: %{
          chronicle_backend: chronicle_backend,
          dag_backend: dag_backend,
          room_version: room_version
        }
      )

  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Chronicle
  alias RadioBeam.Room.Core
  alias RadioBeam.Room.Events

  describe "new/1" do
    test "successfully creates a new simple %Room{}", %{
      room_version: version,
      chronicle_backend: chronicle_backend,
      dag_backend: dag_backend
    } do
      creator_id = Fixtures.user_id()

      assert {%Room{} = room, _pdus} =
               Room.Core.new(version, creator_id, default_deps(),
                 chronicle_backend: chronicle_backend,
                 dag_backend: dag_backend
               )

      assert %AuthorizedEvent{type: "m.room.create"} = Chronicle.get_create_event(room.chronicle)
    end

    test "successfully creates a new room with all the different optional args", %{
      room_version: version,
      chronicle_backend: chronicle_backend,
      dag_backend: dag_backend
    } do
      server_name = RadioBeam.server_name()

      creator_id = Fixtures.user_id()
      invitee_id = Fixtures.user_id()
      maybe_deprecated_string_pl = if version in ~w|1 2 3 4 5 6 7 8 9|, do: "60", else: 60

      power_levels_content = %{
        "users" => %{creator_id => 99},
        "ban" => maybe_deprecated_string_pl,
        "state_default" => 51
      }

      alias_localpart = "computer-rv-#{version}"
      alias = "##{alias_localpart}:#{server_name}"

      deps =
        Map.put(default_deps(), :register_room_alias, fn
          %Room.Alias{localpart: ^alias_localpart, server_name: ^server_name}, _ -> :ok
          other_alias, _ -> raise "room creation checking for alias #{other_alias}"
        end)

      opts = [
        chronicle_backend: chronicle_backend,
        dag_backend: dag_backend,
        power_levels: power_levels_content,
        preset: :trusted_private_chat,
        # override the join_rules of the preset, but name should not affect anything
        addl_state_events: [join_rule_event(), name_event()],
        alias: alias_localpart,
        content: %{"m.federate" => false},
        name: "The Computer Room",
        topic: "this one's for the nerds",
        direct?: true,
        visibility: :public,
        invite: [invitee_id],
        # TODO
        invite_3pid: []
      ]

      assert {%Room{} = room, _pdus} = Room.Core.new(version, creator_id, deps, opts)
      assert %AuthorizedEvent{type: "m.room.create"} = Chronicle.get_create_event(room.chronicle)

      assert {:ok, event_id} = Core.get_state_mapping(room, "m.room.member", creator_id)
      assert {:ok, %{content: %{"membership" => "join"}}} = Chronicle.fetch_event(room.chronicle, event_id)

      pl_content = Map.merge(Events.default_power_level_content(creator_id, version), power_levels_content)

      assert {:ok, event_id} = Core.get_state_mapping(room, "m.room.power_levels")
      assert {:ok, %{content: ^pl_content}} = Chronicle.fetch_event(room.chronicle, event_id)

      # preset trusted_private_chat sets join_rule to "invite", but we override with "knock"
      assert {:ok, event_id} = Core.get_state_mapping(room, "m.room.join_rules")
      assert {:ok, %{content: %{"join_rule" => "knock"}}} = Chronicle.fetch_event(room.chronicle, event_id)

      assert {:ok, event_id} = Core.get_state_mapping(room, "m.room.history_visibility")
      assert {:ok, %{content: %{"history_visibility" => "shared"}}} = Chronicle.fetch_event(room.chronicle, event_id)

      assert {:ok, event_id} = Core.get_state_mapping(room, "m.room.guest_access")
      assert {:ok, %{content: %{"guest_access" => "can_join"}}} = Chronicle.fetch_event(room.chronicle, event_id)

      assert {:ok, event_id} = Core.get_state_mapping(room, "m.room.canonical_alias")
      assert {:ok, %{content: %{"alias" => ^alias}}} = Chronicle.fetch_event(room.chronicle, event_id)

      assert {:ok, event_id} = Core.get_state_mapping(room, "m.room.name")
      assert {:ok, %{content: %{"name" => "The Computer Room"}}} = Chronicle.fetch_event(room.chronicle, event_id)

      assert {:ok, event_id} = Core.get_state_mapping(room, "m.room.topic")

      assert {:ok, %{content: %{"topic" => "this one's for the nerds"}}} =
               Chronicle.fetch_event(room.chronicle, event_id)

      assert {:ok, event_id} = Core.get_state_mapping(room, "m.room.member", invitee_id)

      assert {:ok, %{content: %{"membership" => "invite", "is_direct" => true}}} =
               Chronicle.fetch_event(room.chronicle, event_id)

      # TODO: assert invite_3pid, and visibility
    end
  end

  describe "send/3" do
    setup %{room_version: version, chronicle_backend: chronicle_backend, dag_backend: dag_backend} do
      user_id = Fixtures.user_id()

      {room, _pdus} =
        Room.Core.new(version, user_id, default_deps(), chronicle_backend: chronicle_backend, dag_backend: dag_backend)

      %{room: room, creator_id: user_id}
    end

    test "sends the creator's m.room.message events, adding them to the chronicle/DAG", %{
      room: room,
      creator_id: creator_id
    } do
      msgs = ["test.", "ok I guess this works?"]

      {room, one_of_the_eids} =
        Enum.reduce(msgs, {room, nil}, fn message, {room, _} ->
          assert {:sent, room, event_id, [pdu]} =
                   Room.Core.send(room, Events.text_message(room.id, creator_id, message), default_deps())

          assert pdu.event.type == "m.room.message"
          assert pdu.event.sender == creator_id

          {room, event_id}
        end)

      assert {:ok, %{content: %{"body" => body}}} = Chronicle.fetch_event(room.chronicle, one_of_the_eids)
      assert body in msgs
    end

    test "sends the creator's state updates, updating the room state", %{room: room, creator_id: creator_id} do
      events_to_add = [
        Events.name(room.id, creator_id, "A cool room"),
        Events.topic(room.id, creator_id, "This is a really cool room"),
        Events.topic(room.id, creator_id, "This is a REALLY cool room")
      ]

      room =
        Enum.reduce(events_to_add, room, fn event, room ->
          assert {:sent, room, _event_id, [pdu]} = Room.Core.send(room, event, default_deps())
          assert pdu.event.type == event["type"]
          assert pdu.event.sender == creator_id

          room
        end)

      assert %{{"m.room.name", ""} => name_event_id, {"m.room.topic", ""} => topic_event_id} =
               Core.get_state_mapping(room)

      assert {:ok, %{content: %{"name" => "A cool room"}}} = Chronicle.fetch_event(room.chronicle, name_event_id)

      assert {:ok, %{content: %{"topic" => "This is a REALLY cool room"}}} =
               Chronicle.fetch_event(room.chronicle, topic_event_id)
    end

    test "m.room.canonical_alias events are accepted only if the specified aliases are valid and can be mapped to this room",
         %{
           room: room,
           creator_id: creator_id
         } do
      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "invalid", "localhost")
      assert {:error, :invalid_alias} = Room.Core.send(room, canonical_alias_event, default_deps())

      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "differentroom", "localhost")
      assert {:error, :alias_in_use} = Room.Core.send(room, canonical_alias_event, default_deps())

      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "not_mapped", "localhost")

      assert {:sent, _room, _event_id, [%{event: %{type: "m.room.canonical_alias"}}]} =
               Room.Core.send(room, canonical_alias_event, default_deps())
    end
  end

  defp default_deps do
    %{
      register_room_alias: fn
        %Room.Alias{localpart: "invalid", server_name: "localhost"}, _ -> {:error, :invalid_alias}
        %Room.Alias{localpart: "not_mapped", server_name: "localhost"}, _ -> :ok
        _alias, _ -> {:error, :alias_in_use}
      end
    }
  end

  defp join_rule_event() do
    %{
      "content" => %{"join_rule" => "knock"},
      "state_key" => "",
      "type" => "m.room.join_rules"
    }
  end

  defp name_event() do
    %{
      "content" => %{"name" => "sloppy steak house"},
      "state_key" => "",
      "type" => "m.room.name"
    }
  end
end
