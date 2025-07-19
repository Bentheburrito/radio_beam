defmodule RadioBeam.Room.AuthorizedEventTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Events

  describe "new!/1" do
    test "creates a new message event" do
      room_id = "!asdf"
      user_id = "@user:localhost"
      body = "Hello world"
      auth_event_id = "$1234"

      origin_server_ts = 1234

      text_message_event_attrs =
        room_id
        |> Events.text_message(user_id, body)
        |> Map.put("auth_events", [auth_event_id])
        |> Map.put("origin_server_ts", origin_server_ts)

      {:ok, event_id} = Events.reference_hash(text_message_event_attrs, "11")

      text_message_event_attrs = Map.put(text_message_event_attrs, "id", event_id)

      assert %AuthorizedEvent{
               auth_events: [^auth_event_id],
               content: %{"msgtype" => "m.text", "body" => ^body},
               id: ^event_id,
               origin_server_ts: ^origin_server_ts,
               room_id: ^room_id,
               sender: ^user_id,
               state_key: :none,
               type: "m.room.message",
               unsigned: %{}
             } =
               AuthorizedEvent.new!(text_message_event_attrs)
    end

    test "creates a new state event" do
      room_id = "!asdf"
      user_id = "@user:localhost"
      auth_event_id = "$1234"
      room_version = "11"

      origin_server_ts = 1234

      create_event_attrs =
        room_id
        |> Events.create(user_id, room_version, %{})
        |> Map.put("auth_events", [auth_event_id])
        |> Map.put("origin_server_ts", origin_server_ts)

      {:ok, event_id} = Events.reference_hash(create_event_attrs, room_version)

      create_event_attrs = Map.put(create_event_attrs, "id", event_id)

      assert %AuthorizedEvent{
               auth_events: [^auth_event_id],
               content: %{"room_version" => ^room_version},
               id: ^event_id,
               origin_server_ts: ^origin_server_ts,
               room_id: ^room_id,
               sender: ^user_id,
               state_key: "",
               type: "m.room.create",
               unsigned: %{}
             } =
               AuthorizedEvent.new!(create_event_attrs)
    end

    test "raises if some required field (id) is missing" do
      assert_raise KeyError, fn ->
        "!asdfasdf"
        |> Events.create("@user:localhost", "11", %{})
        |> Map.put("auth_events", ["$asdf"])
        |> Map.put("origin_server_ts", 123)
        |> AuthorizedEvent.new!()
      end
    end
  end
end
