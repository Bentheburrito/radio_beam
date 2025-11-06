defmodule RadioBeam.RoomTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.RoomRegistry

  @room_versions_to_test Application.compile_env!(:radio_beam, [:capabilities, :"m.room_versions", :available])
                         |> Map.keys()

  describe "create/4" do
    setup do
      user = Fixtures.user()
      invitee = Fixtures.user()

      %{creator: user, to_invite: invitee}
    end

    test "successfully creates a minimal room", %{creator: creator} do
      for room_version <- @room_versions_to_test do
        assert {:ok, room_id} = Room.create(creator, version: room_version)
        assert [{pid, _}] = Registry.lookup(RoomRegistry, room_id)
        assert is_pid(pid)
      end
    end

    test "successfully creates a room with all the different optional args", %{creator: creator, to_invite: invitee} do
      server_name = RadioBeam.server_name()

      for room_version <- @room_versions_to_test do
        maybe_deprecated_string_pl = if room_version in ~w|10 11|, do: 60, else: "60"

        power_levels_content = %{
          "users" => %{creator.id => 99},
          "ban" => maybe_deprecated_string_pl,
          "state_default" => 51
        }

        alias_localpart = "computer-rv-#{room_version}"

        opts = [
          power_levels: power_levels_content,
          preset: :trusted_private_chat,
          alias: alias_localpart,
          content: %{"m.federate" => false},
          name: "The Computer Room",
          topic: "this one's for the nerds",
          direct?: true,
          visibility: :public,
          invite: [invitee.id],
          # TODO
          invite_3pid: []
        ]

        assert {:ok, room_id} = Room.create(creator, Keyword.put(opts, :version, room_version))

        :pong = Room.Server.ping(room_id)

        assert {:ok, %{content: %{"name" => "The Computer Room"}}} =
                 Room.get_state(room_id, creator.id, "m.room.name", "")

        alias = "##{alias_localpart}:#{server_name}"
        assert {:ok, ^room_id} = Room.Alias.get_room_id(alias)
        # TODO: assert invite_3pid, and visibility
      end
    end
  end

  describe "joined/1" do
    setup do
      user1 = Fixtures.user("@thehost:localhost")
      user2 = Fixtures.user("@friendoftheshow:localhost")

      %{user1: user1, user2: user2}
    end

    test "lists a user's room appropriately", %{user1: user1, user2: user2} do
      assert [] = Room.joined(user1.id)

      assert {:ok, room_id} = Room.create(user1)

      :pong = Room.Server.ping(room_id)

      assert [^room_id] = user1.id |> Room.joined() |> Enum.to_list()

      assert {:ok, _other_users_room_id} = Room.create(user2)
      assert [^room_id] = user1.id |> Room.joined() |> Enum.to_list()

      assert {:ok, _other_users_room_id} = Room.create(user2, invite: [user1.id])
      assert [^room_id] = user1.id |> Room.joined() |> Enum.to_list()

      assert {:ok, room_id2} = Room.create(user1)
      :pong = Room.Server.ping(room_id2)
      assert Enum.sort([room_id, room_id2]) == user1.id |> Room.joined() |> Enum.sort()
    end
  end

  describe "invite/3" do
    setup do
      user1 = Fixtures.user()
      user2 = Fixtures.user()

      %{user1: user1, user2: user2}
    end

    test "successfully invites a user", %{user1: user1, user2: user2} do
      {:ok, room_id} = Room.create(user1)

      assert {:ok, _event_id} = Room.invite(room_id, user1.id, user2.id)
    end

    test "fails with :unauthorized when the inviter does not have a high enough PL", %{user1: user1, user2: user2} do
      {:ok, room_id} = Room.create(user1, power_levels: %{"invite" => 101})

      assert {:error, :unauthorized} = Room.invite(room_id, user1.id, user2.id)
    end
  end

  describe "join/2" do
    setup do
      user1 = Fixtures.user()
      user2 = Fixtures.user()

      %{user1: user1, user2: user2}
    end

    test "successfully joins the room", %{user1: user1, user2: user2} do
      {:ok, room_id} = Room.create(user1)

      assert {:ok, _event_id} = Room.invite(room_id, user1.id, user2.id)
      reason = "requested assistance"
      assert {:ok, _event_id} = Room.join(room_id, user2.id, reason)
    end

    test "fails with :unauthorized when the joiner has not been invited", %{user1: user1, user2: user2} do
      {:ok, room_id} = Room.create(user1)

      assert {:error, :unauthorized} = Room.join(room_id, user2.id)
    end
  end

  describe "send/4" do
    setup do
      user1 = Fixtures.user()
      user2 = Fixtures.user()

      %{user1: user1, user2: user2}
    end

    test "creator can put a message in the room", %{user1: creator} do
      {:ok, room_id} = Room.create(creator)

      content = %{"msgtype" => "m.text", "body" => "This is a test message"}
      assert {:ok, "$" <> _ = _event_id} = Room.send(room_id, creator.id, "m.room.message", content)
    end

    test "member can put a message in the room if has perms", %{user1: creator, user2: user} do
      {:ok, room_id} = Room.create(creator)
      assert {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      assert {:ok, _event_id} = Room.join(room_id, user.id)

      content = %{"msgtype" => "m.text", "body" => "This is another test message"}
      assert {:ok, "$" <> _ = _event_id} = Room.send(room_id, user.id, "m.room.message", content)
    end

    test "member can't put a message in the room without perms", %{user1: creator, user2: user} do
      {:ok, room_id} = Room.create(creator, power_levels: %{"events" => %{"m.room.message" => 80}})
      assert {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      assert {:ok, _event_id} = Room.join(room_id, user.id)

      content = %{"msgtype" => "m.text", "body" => "I shouldn't be able to send this rn"}
      assert {:error, :unauthorized} = Room.send(room_id, user.id, "m.room.message", content)
    end

    test "member can't put a message in the room without first joining", %{user1: creator, user2: user} do
      {:ok, room_id} = Room.create(creator)
      assert {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)

      content = %{"msgtype" => "m.text", "body" => "I shouldn't be able to send this rn"}
      assert {:error, :unauthorized} = Room.send(room_id, user.id, "m.room.message", content)
    end

    test "will reject duplicate annotations", %{user1: creator, user2: user} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      {:ok, event_id} = Room.send_text_message(room_id, creator.id, "React to this twice")
      rel = %{"m.relates_to" => %{"event_id" => event_id, "rel_type" => "m.annotation", "key" => "👍"}}

      assert {:ok, _} = Room.send(room_id, creator.id, "m.reaction", rel)
      assert {:error, :duplicate_annotation} = Room.send(room_id, creator.id, "m.reaction", rel)
      assert {:ok, _} = Room.send(room_id, user.id, "m.reaction", rel)
      assert {:error, :duplicate_annotation} = Room.send(room_id, user.id, "m.reaction", rel)
    end
  end

  describe "get_event/3" do
    setup do
      user1 = Fixtures.user()
      user2 = Fixtures.user()

      %{user1: user1, user2: user2}
    end

    test "can get an event in a room the calling user is joined to", %{user1: creator, user2: user} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)
      content = %{"msgtype" => "m.text", "body" => "yoOOOOOOOOO"}
      {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)

      assert {:ok, %{id: ^event_id}} = Room.get_event(room_id, user.id, event_id)
    end

    test "returns bundled events", %{user1: creator, user2: user} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)
      content = %{"msgtype" => "m.text", "body" => "yoOOOOOOOOO"}
      {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)

      {:ok, child_id} =
        Room.send(room_id, creator.id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "Yoooooooo (in a thread)",
          "m.relates_to" => %{"event_id" => event_id, "rel_type" => "m.thread"}
        })

      assert {:ok, %{id: ^event_id, bundled_events: [%{id: ^child_id}]}} =
               Room.get_event(room_id, user.id, event_id)
    end

    test "cannot get an event in a room the calling user is not a member of", %{user1: creator, user2: user} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)

      content = %{"msgtype" => "m.text", "body" => "lmao you can't see this"}
      {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)

      assert {:error, :unauthorized} = Room.get_event(room_id, user.id, event_id)
    end

    test "can get an event in a room the calling user was joined to at the time it was sent", %{
      user1: creator,
      user2: user
    } do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)
      {:ok, _event_id} = Room.join(room_id, user.id)

      content = %{"msgtype" => "m.text", "body" => "please leave"}
      {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)
      content = %{"msgtype" => "m.text", "body" => "oh...ok"}
      {:ok, _event_id} = Room.send(room_id, user.id, "m.room.message", content)

      {:ok, _event_id} = Room.leave(room_id, user.id, "cya")

      content = %{"msgtype" => "m.text", "body" => "oh they actually left"}
      {:ok, _event_id} = Room.send(room_id, creator.id, "m.room.message", content)

      assert {:ok, %{id: ^event_id}} = Room.get_event(room_id, user.id, event_id)
    end

    test "can get an event in a shared history room the calling user joined at a later time", %{
      user1: creator,
      user2: user
    } do
      {:ok, room_id} = Room.create(creator, preset: :private_chat)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)

      content = %{"msgtype" => "m.text", "body" => "I hope my friend joins soon"}
      {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)

      assert {:error, :unauthorized} = Room.get_event(room_id, user.id, event_id)

      {:ok, _event_id} = Room.join(room_id, user.id)

      content = %{"msgtype" => "m.text", "body" => "yoooo I'm here now"}
      {:ok, _event_id} = Room.send(room_id, user.id, "m.room.message", content)
      {:ok, _event_id} = Room.leave(room_id, user.id, "nvm gtg")

      assert {:ok, %{id: ^event_id}} = Room.get_event(room_id, user.id, event_id)

      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id, "please come back")
      {:ok, _event_id} = Room.join(room_id, user.id, "ok")
      content = %{"msgtype" => "m.text", "body" => "I'm back"}
      {:ok, event_id2} = Room.send(room_id, user.id, "m.room.message", content)
      {:ok, _event_id} = Room.leave(room_id, user.id, "jk lmao")

      assert {:ok, %{id: ^event_id}} = Room.get_event(room_id, user.id, event_id)
      assert {:ok, %{id: ^event_id2}} = Room.get_event(room_id, user.id, event_id2)
    end

    test "can't get an event in a since-joined-only history room the calling user was joined to at a later time", %{
      user1: creator,
      user2: user
    } do
      {:ok, room_id} = Room.create(creator, addl_state_events: [history_visibility_event("joined")])
      {:ok, _event_id} = Room.invite(room_id, creator.id, user.id)

      content = %{"msgtype" => "m.text", "body" => "I hope my friend joins soon"}
      {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)

      assert {:error, :unauthorized} = Room.get_event(room_id, user.id, event_id)

      {:ok, _event_id} = Room.join(room_id, user.id)

      content = %{"msgtype" => "m.text", "body" => "yoooo I'm here now"}
      {:ok, _event_id} = Room.send(room_id, user.id, "m.room.message", content)
      {:ok, _event_id} = Room.leave(room_id, user.id, "nvm gtg")

      assert {:error, :unauthorized} = Room.get_event(room_id, user.id, event_id)
    end
  end

  describe "redact_event/3,4" do
    setup do
      user = Fixtures.user()
      {:ok, room_id} = Room.create(user)

      %{user: user, room_id: room_id}
    end

    test "redacts a message event if the redactor is the creator", %{user: user, room_id: room_id} do
      {:ok, event_id} = Room.send_text_message(room_id, user.id, "delete me")
      assert {:ok, _redaction_event_id} = Room.redact_event(room_id, user.id, event_id, "meant to be deleted")

      assert {:ok, %{content: content}} = Room.get_event(room_id, user.id, event_id)
      assert 0 = map_size(content)
    end

    test "redacts a message event if the redactor is the sender", %{user: user, room_id: room_id} do
      rando = Fixtures.user()
      {:ok, _event_id} = Room.invite(room_id, user.id, rando.id)
      {:ok, _event_id} = Room.join(room_id, rando.id)

      {:ok, event_id} = Room.send_text_message(room_id, rando.id, "rando's message")

      assert {:ok, _event_id} = Room.redact_event(room_id, rando.id, event_id, "can I delete my own msg? yes")
    end

    test "redacts a message event if the redactor has the 'redact' power", %{user: user, room_id: room_id} do
      rando = Fixtures.user()
      {:ok, _event_id} = Room.invite(room_id, user.id, rando.id)
      {:ok, _event_id} = Room.join(room_id, rando.id)

      {:ok, event_id} = Room.send_text_message(room_id, rando.id, "try to delete me")

      assert {:ok, _event_id} = Room.redact_event(room_id, user.id, event_id, "I will bc I'm the creator")
      assert {:ok, %{content: content}} = Room.get_event(room_id, user.id, event_id)
      assert 0 = map_size(content)
    end

    test "does not apply a redaction against another user if the redactor does not have 'redact' power", %{
      user: user,
      room_id: room_id
    } do
      rando = Fixtures.user()
      {:ok, _event_id} = Room.invite(room_id, user.id, rando.id)
      {:ok, _event_id} = Room.join(room_id, rando.id)

      {:ok, event_id} = Room.send_text_message(room_id, user.id, "try to delete me")

      assert {:ok, _redaction_event_id} = Room.redact_event(room_id, rando.id, event_id, "I can try")
      assert {:ok, %{content: %{"body" => "try to delete me"}}} = Room.get_event(room_id, user.id, event_id)
    end

    test "rejects an unauthorized redactor (does not have 'events -> m.room.redaction' power)", %{user: user} do
      {:ok, room_id} = Room.create(user, power_levels: %{"events" => %{"m.room.redaction" => 5}})

      rando = Fixtures.user()
      {:ok, _event_id} = Room.invite(room_id, user.id, rando.id)
      {:ok, _event_id} = Room.join(room_id, rando.id)

      {:ok, event_id} = Room.send_text_message(room_id, rando.id, "rando's message")

      assert {:error, :unauthorized} = Room.redact_event(room_id, rando.id, event_id, "can I delete my own msg? no")
    end
  end

  describe "get_members/4" do
    setup do
      user1 = Fixtures.user()
      user2 = Fixtures.user()
      user3 = Fixtures.user()

      %{user1: user1, user2: user2, user3: user3}
    end

    test "returns members when the requester is in the room", %{user1: creator, user2: user2, user3: user3} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user3.id)
      {:ok, _event_id} = Room.join(room_id, user2.id)
      {:ok, _event_id} = Room.join(room_id, user3.id)

      assert {:ok, members} = Room.get_members(room_id, user2.id)
      assert 3 = Enum.count(members)
    end

    test "returns unauthorized when requester is not and has never been in the room", %{
      user1: creator,
      user2: user2,
      user3: user3
    } do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user3.id)
      {:ok, _event_id} = Room.join(room_id, user3.id)

      assert {:error, :unauthorized} = Room.get_members(room_id, user2.id)
    end

    test "returns members when the requester was last in the room after leaving", %{
      user1: creator,
      user2: user2,
      user3: user3
    } do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user3.id)
      {:ok, _event_id} = Room.join(room_id, user2.id)
      {:ok, _event_id} = Room.join(room_id, user3.id)
      {:ok, _event_id} = Room.leave(room_id, user2.id)

      assert {:ok, expected} = Room.get_members(room_id, user2.id)

      {:ok, _event_id} = Room.leave(room_id, user3.id)

      assert {:ok, actual} = Room.get_members(room_id, user2.id)
      assert Enum.sort(expected) == Enum.sort(actual)
    end

    test "returns members that pass the given filter", %{
      user1: creator,
      user2: user2,
      user3: user3
    } do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user3.id)
      {:ok, _event_id} = Room.join(room_id, user2.id)

      filter_fn = fn membership -> membership == "join" end
      assert {:ok, members} = Room.get_members(room_id, user2.id, :latest_visible, filter_fn)
      assert 2 = Enum.count(members)

      {:ok, _event_id} = Room.join(room_id, user3.id)

      assert {:ok, members} = Room.get_members(room_id, user2.id, :latest_visible, filter_fn)
      assert 3 = Enum.count(members)

      {:ok, _event_id} = Room.leave(room_id, user3.id)

      assert {:ok, members} = Room.get_members(room_id, user2.id, :latest_visible, filter_fn)
      assert 2 = Enum.count(members)
    end

    test "returns members in the room at the given event ID", %{user1: creator, user2: user2, user3: user3} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)
      {:ok, _event_id} = Room.join(room_id, user2.id)

      content = %{"msgtype" => "m.text", "body" => "hi"}
      {:ok, event_id} = Room.send(room_id, creator.id, "m.room.message", content)

      assert {:ok, members} = Room.get_members(room_id, user2.id, event_id)
      assert 2 = Enum.count(members)

      {:ok, _event_id} = Room.invite(room_id, creator.id, user3.id)
      {:ok, _event_id} = Room.join(room_id, user3.id)

      assert {:ok, members} = Room.get_members(room_id, user2.id, :latest_visible)
      assert 3 = Enum.count(members)

      assert {:ok, members} = Room.get_members(room_id, user2.id, event_id)
      assert 2 = Enum.count(members)

      filter_fn = fn membership -> membership == "join" end

      assert {:ok, members} = Room.get_members(room_id, user2.id, :latest_visible, filter_fn)
      assert 3 = Enum.count(members)

      assert {:ok, members} = Room.get_members(room_id, user2.id, event_id, filter_fn)
      assert 2 = Enum.count(members)
    end
  end

  describe "get_state/2" do
    setup do
      user1 = Fixtures.user()
      user2 = Fixtures.user()

      %{user1: user1, user2: user2}
    end

    test "returns cur room state when the requester is in the room", %{user1: creator} do
      {:ok, room_id} = Room.create(creator)

      :pong = Room.Server.ping(room_id)

      assert {:ok, state_event_stream} = Room.get_state(room_id, creator.id)
      assert 6 = Enum.count(state_event_stream)
    end

    test "returns unauthorized when requester is not and has never been in the room", %{user1: creator, user2: user2} do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)

      assert {:error, :unauthorized} = Room.get_state(room_id, user2.id)
    end

    test "returns the room state at the time the requester left", %{
      user1: creator,
      user2: user2
    } do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)
      {:ok, _event_id} = Room.join(room_id, user2.id)

      assert {:ok, state_event_stream} = Room.get_state(room_id, user2.id)
      assert 7 = Enum.count(state_event_stream)

      {:ok, _event_id} = Room.leave(room_id, user2.id)

      assert {:ok, state_event_stream_after_leave} = Room.get_state(room_id, user2.id)

      assert state_event_stream_after_leave
             |> Stream.reject(&(&1.type == "m.room.member" and &1.state_key == user2.id))
             |> Enum.sort() ==
               state_event_stream
               |> Stream.reject(&(&1.type == "m.room.member" and &1.state_key == user2.id))
               |> Enum.sort()

      {:ok, _event_id} = Room.set_name(room_id, creator.id, "A New Name")

      assert {:ok, state_event_stream_after_name} = Room.get_state(room_id, user2.id)
      assert Enum.sort(state_event_stream_after_name) == Enum.sort(state_event_stream_after_leave)
    end
  end

  describe "get_state/4" do
    setup do
      user1 = Fixtures.user()
      user2 = Fixtures.user()

      %{user1: user1, user2: user2}
    end

    test "returns state content when the requester is in the room", %{user1: creator} do
      {:ok, room_id} = Room.create(creator)

      :pong = Room.Server.ping(room_id)

      assert {:ok, %{content: %{"membership" => "join"}}} =
               Room.get_state(room_id, creator.id, "m.room.member", creator.id)
    end

    test "returns unauthorized when requester is not and has never been in the room", %{
      user1: creator,
      user2: user2
    } do
      {:ok, room_id} = Room.create(creator)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)

      assert {:error, :unauthorized} = Room.get_state(room_id, user2.id, "m.room.member", user2.id)
    end

    test "returns not_found when the key doesn't exist in the state", %{user1: creator} do
      {:ok, room_id} = Room.create(creator)
      assert {:error, :not_found} = Room.get_state(room_id, creator.id, "m.room.message_board", "")
    end

    test "returns the state content at the time the requester left", %{
      user1: creator,
      user2: user2
    } do
      topic = "There are monsters on this world"
      {:ok, room_id} = Room.create(creator, topic: topic)
      {:ok, _event_id} = Room.invite(room_id, creator.id, user2.id)
      {:ok, _event_id} = Room.join(room_id, user2.id)

      assert {:ok, %{content: %{"topic" => ^topic}} = event} = Room.get_state(room_id, user2.id, "m.room.topic", "")
      assert {:error, :not_found} = Room.get_state(room_id, user2.id, "m.room.name", "")

      {:ok, _event_id} = Room.leave(room_id, user2.id)
      {:ok, _event_id} = Room.set_name(room_id, creator.id, "A New Name")

      {:ok, _event_id} =
        Room.put_state(room_id, creator.id, "m.room.topic", "", %{"topic" => "THERE ARE MONSTERS ON THIS WORLD!?"})

      assert {:ok, ^event} = Room.get_state(room_id, user2.id, "m.room.topic", "")
      assert {:error, :not_found} = Room.get_state(room_id, user2.id, "m.room.name", "")
    end
  end

  defp history_visibility_event(visibility) do
    %{
      "content" => %{"history_visibility" => visibility},
      "state_key" => "",
      "type" => "m.room.history_visibility"
    }
  end
end
