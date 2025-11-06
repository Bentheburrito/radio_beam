defmodule RadioBeam.Room.CoreTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.Events
  alias RadioBeam.Room
  alias RadioBeam.Room.DAG
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.State

  @room_versions_to_test Application.compile_env!(:radio_beam, [:capabilities, :"m.room_versions", :available])
                         |> Map.keys()

  describe "new/1" do
    test "successfully creates a new simple %Room{}" do
      for version <- @room_versions_to_test do
        creator_id = Fixtures.user_id()

        assert {%Room{} = room, _pdus} = Room.Core.new(version, creator_id, default_deps())
        assert %PDU{event: %{type: "m.room.create"}} = DAG.root!(room.dag)
        assert 6 = DAG.size(room.dag)
        assert 6 = State.size(room.state)

        assert {:ok, %{event: %{content: %{"membership" => "join"}}}} =
                 State.fetch(room.state, "m.room.member", creator_id)
      end
    end

    test "successfully creates a new room with all the different optional args" do
      server_name = RadioBeam.server_name()

      for version <- @room_versions_to_test do
        creator_id = Fixtures.user_id()
        invitee_id = Fixtures.user_id()
        maybe_deprecated_string_pl = if version in ~w|10 11|, do: 60, else: "60"

        power_levels_content = %{
          "users" => %{creator_id => 99},
          "ban" => maybe_deprecated_string_pl,
          "state_default" => 51
        }

        alias_localpart = "computer-rv-#{version}"
        alias = "##{alias_localpart}:#{server_name}"

        deps =
          Map.put(default_deps(), :register_room_alias, fn
            ^alias, _ -> :ok
            other_alias, _ -> raise "room creation checking for alias #{other_alias}"
          end)

        opts = [
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
        assert %PDU{event: %{type: "m.room.create"}} = DAG.root!(room.dag)
        assert 12 = DAG.size(room.dag)
        assert 10 = State.size(room.state)

        assert {:ok, %{event: %{content: %{"membership" => "join"}}}} =
                 State.fetch(room.state, "m.room.member", creator_id)

        pl_content = Map.merge(Room.Events.default_power_level_content(creator_id), power_levels_content)

        assert {:ok, %{event: %{content: ^pl_content}}} = State.fetch(room.state, "m.room.power_levels")

        # preset trusted_private_chat sets join_rule to "invite", but we override with "knock"
        assert {:ok, %{event: %{content: %{"join_rule" => "knock"}}}} = State.fetch(room.state, "m.room.join_rules")

        assert {:ok, %{event: %{content: %{"history_visibility" => "shared"}}}} =
                 State.fetch(room.state, "m.room.history_visibility")

        assert {:ok, %{event: %{content: %{"guest_access" => "can_join"}}}} =
                 State.fetch(room.state, "m.room.guest_access")

        assert {:ok, %{event: %{content: %{"alias" => ^alias}}}} = State.fetch(room.state, "m.room.canonical_alias")

        assert {:ok, %{event: %{content: %{"name" => "The Computer Room"}}}} = State.fetch(room.state, "m.room.name")

        assert {:ok, %{event: %{content: %{"topic" => "this one's for the nerds"}}}} =
                 State.fetch(room.state, "m.room.topic")

        assert {:ok, %{event: %{content: %{"membership" => "invite", "is_direct" => true}}}} =
                 State.fetch(room.state, "m.room.member", invitee_id)

        # TODO: assert invite_3pid, and visibility
      end
    end
  end

  describe "send/3" do
    setup do
      user_id = Fixtures.user_id()
      {room, _pdus} = Room.Core.new("11", user_id, default_deps())
      %{room: room, creator_id: user_id}
    end

    test "adds the creator's m.room.message events to the DAG", %{room: room, creator_id: creator_id} do
      room =
        Enum.reduce(["test.", "ok I guess this works?"], room, fn message, room ->
          assert {:sent, room, pdu} =
                   Room.Core.send(room, Events.text_message(room.id, creator_id, message), default_deps())

          assert pdu.event.type == "m.room.message"
          assert pdu.event.sender == creator_id

          room
        end)

      assert 8 = DAG.size(room.dag)
      assert 6 = State.size(room.state)
    end

    test "adds the creator's state updates to the DAG and room state", %{room: room, creator_id: creator_id} do
      events_to_add = [
        Events.name(room.id, creator_id, "A cool room"),
        Events.topic(room.id, creator_id, "This is a really cool room"),
        Events.topic(room.id, creator_id, "This is a REALLY cool room")
      ]

      room =
        Enum.reduce(events_to_add, room, fn event, room ->
          assert {:sent, room, pdu} = Room.Core.send(room, event, default_deps())
          assert pdu.event.type == event["type"]
          assert pdu.event.sender == creator_id

          room
        end)

      assert 9 = DAG.size(room.dag)
      assert 8 = State.size(room.state)
    end

    test "m.room.canonical_alias events are accepted only if the specified aliases are valid and can be mapped to this room",
         %{
           room: room,
           creator_id: creator_id
         } do
      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "invalid", "localhost")
      assert {:error, :invalid_alias} = Room.Core.send(room, canonical_alias_event, default_deps())

      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "differentroom", "localhost")
      assert {:error, :alias_room_id_mismatch} = Room.Core.send(room, canonical_alias_event, default_deps())

      canonical_alias_event = Events.canonical_alias(room.id, creator_id, "not_mapped", "localhost")

      assert {:sent, _room, %{event: %{type: "m.room.canonical_alias"}}} =
               Room.Core.send(room, canonical_alias_event, default_deps())
    end
  end

  defp default_deps do
    %{
      register_room_alias: fn
        "#invalid:localhost", _ -> {:error, :invalid_alias}
        "#not_mapped:localhost", _ -> :ok
        _alias, _ -> {:error, :already_registered}
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
