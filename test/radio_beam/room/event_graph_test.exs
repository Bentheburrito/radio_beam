defmodule RadioBeam.Room.EventGraphTest do
  use ExUnit.Case, async: true

  alias Polyjuice.Util.Identifiers.V1.RoomIdentifier
  alias RadioBeam.PDU
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.EventGraph.PaginationToken
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.EventGraph

  describe "append/3" do
    setup do
      user = Fixtures.user()
      room = %Room{state: %{}, version: "11", id: "!asdf12344567"}
      %{user: user, room: room}
    end

    test "succeeds with an m.room.create event", %{user: user, room: room} do
      create_content = %{"m.federate" => false}

      create_event = room.id |> Events.create(user.id, room.version, create_content) |> auth_event

      assert {:ok, %PDU{depth: 1, chunk: 0, room_id: room_id, prev_events: []}} =
               EventGraph.append(room, [], create_event)

      assert room_id == room.id
    end

    test "adds one to its parents' depth, keeping the chunk the same", %{user: user, room: room} do
      create_event = room.id |> Events.create(user.id, room.version, %{}) |> auth_event()
      name_event1 = room.id |> Events.name(user.id, "My new Room") |> auth_event()
      name_event2 = room.id |> Events.name(user.id, "My New Room") |> auth_event()
      name_event3 = room.id |> Events.name(user.id, "My New Room") |> auth_event()

      room_id = room.id

      {:ok, %PDU{depth: 1, chunk: 0, room_id: ^room_id, prev_events: [], event_id: create_id} = create_pdu} =
        EventGraph.append(room, [], create_event)

      {:ok, %PDU{depth: 2, chunk: 0, room_id: ^room_id, prev_events: [^create_id], event_id: name1_id} = name_pdu1} =
        EventGraph.append(room, [create_pdu], name_event1)

      {:ok, %PDU{depth: 3, chunk: 0, room_id: ^room_id, prev_events: [^name1_id]}} =
        EventGraph.append(room, [name_pdu1], name_event2)

      {:ok, %PDU{depth: 2, chunk: 0, room_id: ^room_id, prev_events: [^create_id]}} =
        EventGraph.append(room, [create_pdu], name_event3)
    end

    test "puts previous state content under unsigned.prev_content", %{user: user, room: room} do
      create_event = room.id |> Events.create(user.id, room.version, %{}) |> auth_event()
      name_event1 = room.id |> Events.name(user.id, "My new Room") |> auth_event()
      name_event2 = room.id |> Events.name(user.id, "My New Room") |> auth_event()

      {:ok, %PDU{unsigned: %{"prev_content" => nil}} = create_pdu} =
        EventGraph.append(room, [], create_event)

      room = Room.Core.update_state(room, create_pdu)

      {:ok, %PDU{unsigned: %{"prev_content" => nil}} = name_pdu1} =
        EventGraph.append(room, [create_pdu], name_event1)

      room = Room.Core.update_state(room, name_pdu1)

      {:ok, %PDU{unsigned: %{"prev_content" => %{"name" => "My new Room"}}}} =
        EventGraph.append(room, [name_pdu1], name_event2)
    end

    test "does not allow parents of different depths", %{user: user, room: room} do
      create_event = room.id |> Events.create(user.id, room.version, %{}) |> auth_event()
      name_event1 = room.id |> Events.name(user.id, "My new Room") |> auth_event()
      name_event2 = room.id |> Events.name(user.id, "My New Room") |> auth_event()

      room_id = room.id

      {:ok, %PDU{depth: 1, chunk: 0, room_id: ^room_id, prev_events: [], event_id: create_id} = create_pdu} =
        EventGraph.append(room, [], create_event)

      {:ok, %PDU{depth: 2, chunk: 0, room_id: ^room_id, prev_events: [^create_id]} = name_pdu1} =
        EventGraph.append(room, [create_pdu], name_event1)

      {:error, :unrepresentable_parent_rel} = EventGraph.append(room, [create_pdu, name_pdu1], name_event2)
    end

    test "requires an event to be authorized", %{user: user, room: room} do
      create_event = Events.create(room.id, user.id, room.version, %{})

      {:error, %{errors: [auth_events: {"can't be blank", _}]}} = EventGraph.append(room, [], create_event)
    end

    test "does not append a non-m.room.create PDU with no parent(s)", %{user: user, room: room} do
      name_event1 = room.id |> Events.name(user.id, "My new Room") |> auth_event()

      {:error, :empty_parent_list} = EventGraph.append(room, [], name_event1)
    end
  end

  describe "root/1" do
    setup :simple_graph

    test "gets the root of the given room", %{room: room, root: root} do
      assert {:ok, ^root} = EventGraph.root(room.id)
    end

    test "returns :not_found when the room doesn't exist" do
      assert {:error, :not_found} = EventGraph.root("!asjdhgf")
    end
  end

  describe "tip/1" do
    setup :simple_graph

    test "gets the tip of the given room", %{room: room, tip: tip} do
      assert {:ok, ^tip} = EventGraph.tip(room.id)
    end

    test "returns :not_found when the room doesn't exist" do
      assert {:error, :not_found} = EventGraph.root("!asjdhgf1342")
    end
  end

  describe "stream_all_since/2,3" do
    setup do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)

      {:ok, since_pdu} = EventGraph.tip(room_id)
      since = PaginationToken.new(since_pdu, :forward)

      {:ok, _} = Fixtures.send_text_msg(room_id, user.id, "Testing 123")
      {:ok, _} = Fixtures.send_text_msg(room_id, user.id, "guess it works")

      %{room_id: room_id, user: user, since: since, since_pdu: since_pdu}
    end

    defp stream_and_sort(room_id, since) do
      room_id |> EventGraph.stream_all_since(since) |> Enum.sort_by(&{&1.arrival_time, &1.arrival_order})
    end

    test "gets all new messages since `since`", %{room_id: room_id, since: since} do
      assert [e1, e2] = stream_and_sort(room_id, since)

      assert %{content: %{"body" => "Testing 123"}} = e1
      assert %{content: %{"body" => "guess it works"}} = e2
    end

    test "returns nothing if there have been no new events since `since`", %{room_id: room_id} do
      {:ok, tip} = EventGraph.tip(room_id)
      token = PaginationToken.new(tip, :forward)

      assert [] = stream_and_sort(room_id, token)
    end

    test "returns events where the first event comes after the event_id in the given since token", %{
      room_id: room_id,
      since: since
    } do
      [e1, _e2] = stream_and_sort(room_id, since)

      assert since.event_ids == e1.prev_events
    end

    test "returns an event that arrived late, even if its topologically 'earlier' than `since`", %{
      room_id: room_id,
      since: since,
      since_pdu: since_pdu,
      user: user
    } do
      {:ok, room} = Room.get(room_id)
      {:ok, parents} = Repo.get_all(PDU, since_pdu.prev_events)

      event_params =
        room_id
        |> Events.message(user.id, "m.room.message", %{"msgtype" => "m.text", "body" => "ello from down unda"})
        |> auth_event()

      {:ok, e_late} = EventGraph.append(room, parents, event_params)
      Repo.insert(e_late)

      assert [e1, e2, ^e_late] = stream_and_sort(room_id, since)

      assert %{content: %{"body" => "Testing 123"}} = e1
      assert %{content: %{"body" => "guess it works"}} = e2
    end
  end

  # TODO: add some tests here that use a PaginationToken, not just the since_pdu
  describe "traverse/2" do
    setup do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)

      {:ok, since_pdu} = EventGraph.tip(room_id)
      since = PaginationToken.new(since_pdu, :backward)

      {:ok, _} = Fixtures.send_text_msg(room_id, user.id, "Testing 123")
      {:ok, _} = Fixtures.send_text_msg(room_id, user.id, "guess it works")

      %{room_id: room_id, user: user, since: since, since_pdu: since_pdu}
    end

    test "can traverse from the beginning of the room", %{room_id: room_id, user: %{id: user_id}} do
      assert {:ok, pdu_stream, :tip} = EventGraph.traverse(room_id, :root)

      Repo.transaction(fn ->
        assert [
                 %PDU{type: "m.room.create"},
                 %PDU{type: "m.room.member", state_key: ^user_id},
                 %PDU{type: "m.room.power_levels"},
                 %PDU{type: "m.room.join_rules"},
                 %PDU{type: "m.room.history_visibility"},
                 %PDU{type: "m.room.guest_access"},
                 %PDU{type: "m.room.message"},
                 %PDU{type: "m.room.message"}
               ] = Enum.to_list(pdu_stream)
      end)
    end

    test "can traverse from the end of the room", %{room_id: room_id, user: %{id: user_id}} do
      assert {:ok, pdu_stream, :root} = EventGraph.traverse(room_id, :tip)

      assert [
               %PDU{type: "m.room.message"},
               %PDU{type: "m.room.message"},
               %PDU{type: "m.room.guest_access"},
               %PDU{type: "m.room.history_visibility"},
               %PDU{type: "m.room.join_rules"},
               %PDU{type: "m.room.power_levels"},
               %PDU{type: "m.room.member", state_key: ^user_id},
               %PDU{type: "m.room.create"}
             ] = Enum.to_list(pdu_stream)
    end

    test "can traverse backward from an arbitrary PDU", %{room_id: room_id, user: %{id: user_id}, since_pdu: since_pdu} do
      assert {:ok, pdu_stream, :root} = EventGraph.traverse(room_id, {since_pdu.event_id, :backward})

      assert [
               %PDU{type: "m.room.history_visibility"},
               %PDU{type: "m.room.join_rules"},
               %PDU{type: "m.room.power_levels"},
               %PDU{type: "m.room.member", state_key: ^user_id},
               %PDU{type: "m.room.create"}
             ] = Enum.to_list(pdu_stream)
    end

    test "can traverse forward from an arbitrary PDU", %{room_id: room_id, since_pdu: since_pdu} do
      assert {:ok, pdu_stream, :tip} = EventGraph.traverse(room_id, {since_pdu.event_id, :forward})

      Repo.transaction(fn ->
        assert [
                 %PDU{type: "m.room.message"},
                 %PDU{type: "m.room.message"}
               ] = Enum.to_list(pdu_stream)
      end)
    end

    test "will return an :ambiguous_token error when the since token doesn't hold a known event for the given room_id",
         %{room_id: room_id} do
      token = PaginationToken.new(0, :forward)
      assert {:error, :ambiguous_token} = EventGraph.traverse(room_id, {token, :forward})
    end
  end

  defp auth_event(event), do: Map.put(event, "auth_events", [])

  defp simple_graph(_context) do
    user = Fixtures.user()
    room = %Room{state: %{}, version: "11", id: RoomIdentifier.generate("localhost") |> to_string()}

    create_event = room.id |> Events.create(user.id, room.version, %{}) |> auth_event()
    name_event = room.id |> Events.name(user.id, "Cool room!") |> auth_event()

    message_event =
      room.id
      |> Events.message(user.id, "m.room.message", %{
        "msgtype" => "m.text",
        "body" => "this room will be really cool one day"
      })
      |> auth_event()

    pdus =
      for event <- [create_event, name_event, message_event], reduce: [] do
        pdus ->
          parents = pdus |> List.first() |> List.wrap()
          {:ok, pdu} = EventGraph.append(room, parents, event)
          {:ok, ^pdu} = Repo.insert(pdu)
          [pdu | pdus]
      end

    %{user: user, room: room, root: List.last(pdus), tip: hd(pdus)}
  end
end
