defmodule RadioBeam.RoomTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.RoomRegistry

  @room_versions_to_test Application.compile_env!(:radio_beam, [:capabilities, :"m.room_versions", :available])
                         |> Map.keys()

  describe "create/4" do
    setup do
      account = Fixtures.create_account()
      invitee = Fixtures.create_account()

      %{creator: account, to_invite: invitee}
    end

    test "successfully creates a minimal room", %{creator: creator} do
      for room_version <- @room_versions_to_test do
        assert {:ok, room_id} = Room.create(creator.user_id, version: room_version)
        assert [{pid, _}] = Registry.lookup(RoomRegistry, room_id)
        assert is_pid(pid)
      end
    end

    test "successfully creates a room with all the different optional args", %{creator: creator, to_invite: invitee} do
      server_name = RadioBeam.server_name()

      for room_version <- @room_versions_to_test do
        maybe_deprecated_string_pl = if room_version in ~w|10 11|, do: 60, else: "60"

        power_levels_content = %{
          "users" => %{creator.user_id => 99},
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
          invite: [invitee.user_id],
          invite_3pid: []
        ]

        assert {:ok, room_id} = Room.create(creator.user_id, Keyword.put(opts, :version, room_version))

        :pong = Room.Server.ping(room_id)

        assert {:ok, %{content: %{"name" => "The Computer Room"}}} =
                 Room.get_state(room_id, creator.user_id, "m.room.name", "")

        {:ok, alias} = Room.Alias.new("##{alias_localpart}:#{server_name}")
        assert {:ok, ^room_id} = Room.lookup_id_by_alias(alias)
        # TODO: assert invite_3pid, and visibility
      end
    end
  end

  describe "bind_alias_to_room/2" do
    test "succeeds when no other alias is bound to the room" do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, alias} = Room.Alias.new("#coffeetalk:localhost")
      :ok = Room.bind_alias_to_room(alias, room_id)
    end

    test "errors with :alias_in_use when the given alias is already mapped to a room ID" do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, alias} = Room.Alias.new("#teatalk:localhost")
      :ok = Room.bind_alias_to_room(alias, room_id)

      {:ok, another_room_id} = Room.create(account.user_id)
      assert {:error, :alias_in_use} = Room.bind_alias_to_room(alias, another_room_id)
    end

    test "errors with :room_does_not_exist when the given alias is already mapped to a room ID" do
      {:ok, alias} = Room.Alias.new("#justwaterforme:localhost")
      assert {:error, :room_does_not_exist} = Room.bind_alias_to_room(alias, Fixtures.room_id())
    end

    test "errors with :invalid_or_unknown_server_name when servername does not match this homeserver" do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)
      {:ok, alias} = Room.Alias.new("#hellooooooworld:blahblah")
      assert {:error, :invalid_or_unknown_server_name} = Room.bind_alias_to_room(alias, room_id)
    end
  end

  describe "joined/1" do
    setup do
      account1 = Fixtures.create_account("@thehost:localhost")
      account2 = Fixtures.create_account("@friendoftheshow:localhost")

      %{account1: account1, account2: account2}
    end

    test "lists a user's room appropriately", %{account1: account1, account2: account2} do
      assert [] = Room.joined(account1.user_id)

      assert {:ok, room_id} = Room.create(account1.user_id)

      :pong = Room.Server.ping(room_id)

      assert [^room_id] = account1.user_id |> Room.joined() |> Enum.to_list()

      assert {:ok, _other_users_room_id} = Room.create(account2.user_id)
      assert [^room_id] = account1.user_id |> Room.joined() |> Enum.to_list()

      assert {:ok, _other_users_room_id} = Room.create(account2.user_id, invite: [account1.user_id])
      assert [^room_id] = account1.user_id |> Room.joined() |> Enum.to_list()

      assert {:ok, room_id2} = Room.create(account1.user_id)
      :pong = Room.Server.ping(room_id2)
      assert Enum.sort([room_id, room_id2]) == account1.user_id |> Room.joined() |> Enum.sort()
    end
  end

  describe "invite/3" do
    setup do
      account1 = Fixtures.create_account()
      account2 = Fixtures.create_account()

      %{account1: account1, account2: account2}
    end

    test "successfully invites a user", %{account1: account1, account2: account2} do
      {:ok, room_id} = Room.create(account1.user_id)

      assert {:ok, _event_id} = Room.invite(room_id, account1.user_id, account2.user_id)
    end

    test "fails with :unauthorized when the inviter does not have a high enough PL", %{
      account1: account1,
      account2: account2
    } do
      {:ok, room_id} = Room.create(account1.user_id, power_levels: %{"invite" => 101})

      assert {:error, :unauthorized} = Room.invite(room_id, account1.user_id, account2.user_id)
    end
  end

  describe "join/2" do
    setup do
      account1 = Fixtures.create_account()
      account2 = Fixtures.create_account()

      %{account1: account1, account2: account2}
    end

    test "successfully joins the room", %{account1: account1, account2: account2} do
      {:ok, room_id} = Room.create(account1.user_id)

      assert {:ok, _event_id} = Room.invite(room_id, account1.user_id, account2.user_id)
      reason = "requested assistance"
      assert {:ok, _event_id} = Room.join(room_id, account2.user_id, reason)
    end

    test "fails with :unauthorized when the joiner has not been invited", %{account1: account1, account2: account2} do
      {:ok, room_id} = Room.create(account1.user_id)

      assert {:error, :unauthorized} = Room.join(room_id, account2.user_id)
    end
  end

  describe "send/4" do
    setup do
      account1 = Fixtures.create_account()
      account2 = Fixtures.create_account()

      %{account1: account1, account2: account2}
    end

    test "creator can put a message in the room", %{account1: creator} do
      {:ok, room_id} = Room.create(creator.user_id)

      content = %{"msgtype" => "m.text", "body" => "This is a test message"}
      assert {:ok, "$" <> _ = _event_id} = Room.send(room_id, creator.user_id, "m.room.message", content)
    end

    test "member can put a message in the room if has perms", %{account1: creator, account2: account} do
      {:ok, room_id} = Room.create(creator.user_id)
      assert {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)
      assert {:ok, _event_id} = Room.join(room_id, account.user_id)

      content = %{"msgtype" => "m.text", "body" => "This is another test message"}
      assert {:ok, "$" <> _ = _event_id} = Room.send(room_id, account.user_id, "m.room.message", content)
    end

    test "member can't put a message in the room without perms", %{account1: creator, account2: account} do
      {:ok, room_id} = Room.create(creator.user_id, power_levels: %{"events" => %{"m.room.message" => 80}})
      assert {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)
      assert {:ok, _event_id} = Room.join(room_id, account.user_id)

      content = %{"msgtype" => "m.text", "body" => "I shouldn't be able to send this rn"}
      assert {:error, :unauthorized} = Room.send(room_id, account.user_id, "m.room.message", content)
    end

    test "member can't put a message in the room without first joining", %{account1: creator, account2: account} do
      {:ok, room_id} = Room.create(creator.user_id)
      assert {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)

      content = %{"msgtype" => "m.text", "body" => "I shouldn't be able to send this rn"}
      assert {:error, :unauthorized} = Room.send(room_id, account.user_id, "m.room.message", content)
    end

    test "will reject duplicate annotations", %{account1: creator, account2: account} do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)
      {:ok, _event_id} = Room.join(room_id, account.user_id)

      {:ok, event_id} = Room.send_text_message(room_id, creator.user_id, "React to this twice")
      rel = %{"m.relates_to" => %{"event_id" => event_id, "rel_type" => "m.annotation", "key" => "👍"}}

      assert {:ok, _} = Room.send(room_id, creator.user_id, "m.reaction", rel)
      assert {:error, :duplicate_annotation} = Room.send(room_id, creator.user_id, "m.reaction", rel)
      assert {:ok, _} = Room.send(room_id, account.user_id, "m.reaction", rel)
      assert {:error, :duplicate_annotation} = Room.send(room_id, account.user_id, "m.reaction", rel)
    end
  end

  describe "get_event/3" do
    setup do
      account1 = Fixtures.create_account()
      account2 = Fixtures.create_account()

      %{account1: account1, account2: account2}
    end

    test "can get an event in a room the calling user is joined to", %{account1: creator, account2: account} do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)
      {:ok, _event_id} = Room.join(room_id, account.user_id)
      content = %{"msgtype" => "m.text", "body" => "yoOOOOOOOOO"}
      {:ok, event_id} = Room.send(room_id, creator.user_id, "m.room.message", content)

      assert {:ok, %{id: ^event_id}} = Room.get_event(room_id, account.user_id, event_id)
    end

    test "returns bundled events", %{account1: creator, account2: account} do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)
      {:ok, _event_id} = Room.join(room_id, account.user_id)
      content = %{"msgtype" => "m.text", "body" => "yoOOOOOOOOO"}
      {:ok, event_id} = Room.send(room_id, creator.user_id, "m.room.message", content)

      {:ok, child_id} =
        Room.send(room_id, creator.user_id, "m.room.message", %{
          "msgtype" => "m.text",
          "body" => "Yoooooooo (in a thread)",
          "m.relates_to" => %{"event_id" => event_id, "rel_type" => "m.thread"}
        })

      assert {:ok, %{id: ^event_id, bundled_events: [%{id: ^child_id}]}} =
               Room.get_event(room_id, account.user_id, event_id)
    end

    test "cannot get an event in a room the calling user is not a member of", %{account1: creator, account2: account} do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)

      content = %{"msgtype" => "m.text", "body" => "lmao you can't see this"}
      {:ok, event_id} = Room.send(room_id, creator.user_id, "m.room.message", content)

      assert {:error, :unauthorized} = Room.get_event(room_id, account.user_id, event_id)
    end

    test "can get an event in a room the calling user was joined to at the time it was sent", %{
      account1: creator,
      account2: account
    } do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)
      {:ok, _event_id} = Room.join(room_id, account.user_id)

      content = %{"msgtype" => "m.text", "body" => "please leave"}
      {:ok, event_id} = Room.send(room_id, creator.user_id, "m.room.message", content)
      content = %{"msgtype" => "m.text", "body" => "oh...ok"}
      {:ok, _event_id} = Room.send(room_id, account.user_id, "m.room.message", content)

      {:ok, _event_id} = Room.leave(room_id, account.user_id, "cya")

      content = %{"msgtype" => "m.text", "body" => "oh they actually left"}
      {:ok, _event_id} = Room.send(room_id, creator.user_id, "m.room.message", content)

      assert {:ok, %{id: ^event_id}} = Room.get_event(room_id, account.user_id, event_id)
    end

    test "can get an event in a shared history room the calling user joined at a later time", %{
      account1: creator,
      account2: account
    } do
      {:ok, room_id} = Room.create(creator.user_id, preset: :private_chat)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)

      content = %{"msgtype" => "m.text", "body" => "I hope my friend joins soon"}
      {:ok, event_id} = Room.send(room_id, creator.user_id, "m.room.message", content)

      assert {:error, :unauthorized} = Room.get_event(room_id, account.user_id, event_id)

      {:ok, _event_id} = Room.join(room_id, account.user_id)

      content = %{"msgtype" => "m.text", "body" => "yoooo I'm here now"}
      {:ok, _event_id} = Room.send(room_id, account.user_id, "m.room.message", content)
      {:ok, _event_id} = Room.leave(room_id, account.user_id, "nvm gtg")

      assert {:ok, %{id: ^event_id}} = Room.get_event(room_id, account.user_id, event_id)

      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id, "please come back")
      {:ok, _event_id} = Room.join(room_id, account.user_id, "ok")
      content = %{"msgtype" => "m.text", "body" => "I'm back"}
      {:ok, event_id2} = Room.send(room_id, account.user_id, "m.room.message", content)
      {:ok, _event_id} = Room.leave(room_id, account.user_id, "jk lmao")

      assert {:ok, %{id: ^event_id}} = Room.get_event(room_id, account.user_id, event_id)
      assert {:ok, %{id: ^event_id2}} = Room.get_event(room_id, account.user_id, event_id2)
    end

    test "can't get an event in a since-joined-only history room the calling user was joined to at a later time", %{
      account1: creator,
      account2: account
    } do
      {:ok, room_id} = Room.create(creator.user_id, addl_state_events: [history_visibility_event("joined")])
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account.user_id)

      content = %{"msgtype" => "m.text", "body" => "I hope my friend joins soon"}
      {:ok, event_id} = Room.send(room_id, creator.user_id, "m.room.message", content)

      assert {:error, :unauthorized} = Room.get_event(room_id, account.user_id, event_id)

      {:ok, _event_id} = Room.join(room_id, account.user_id)

      content = %{"msgtype" => "m.text", "body" => "yoooo I'm here now"}
      {:ok, _event_id} = Room.send(room_id, account.user_id, "m.room.message", content)
      {:ok, _event_id} = Room.leave(room_id, account.user_id, "nvm gtg")

      assert {:error, :unauthorized} = Room.get_event(room_id, account.user_id, event_id)
    end
  end

  describe "redact_event/3,4" do
    setup do
      account = Fixtures.create_account()
      {:ok, room_id} = Room.create(account.user_id)

      %{account: account, room_id: room_id}
    end

    test "redacts a message event if the redactor is the creator", %{account: account, room_id: room_id} do
      {:ok, event_id} = Room.send_text_message(room_id, account.user_id, "delete me")
      assert {:ok, _redaction_event_id} = Room.redact_event(room_id, account.user_id, event_id, "meant to be deleted")

      assert {:ok, %{content: content}} = Room.get_event(room_id, account.user_id, event_id)
      assert 0 = map_size(content)
    end

    test "redacts a message event if the redactor is the sender", %{account: account, room_id: room_id} do
      rando = Fixtures.create_account()
      {:ok, _event_id} = Room.invite(room_id, account.user_id, rando.user_id)
      {:ok, _event_id} = Room.join(room_id, rando.user_id)

      {:ok, event_id} = Room.send_text_message(room_id, rando.user_id, "rando's message")

      assert {:ok, _event_id} = Room.redact_event(room_id, rando.user_id, event_id, "can I delete my own msg? yes")
    end

    test "redacts a message event if the redactor has the 'redact' power", %{account: account, room_id: room_id} do
      rando = Fixtures.create_account()
      {:ok, _event_id} = Room.invite(room_id, account.user_id, rando.user_id)
      {:ok, _event_id} = Room.join(room_id, rando.user_id)

      {:ok, event_id} = Room.send_text_message(room_id, rando.user_id, "try to delete me")

      assert {:ok, _event_id} = Room.redact_event(room_id, account.user_id, event_id, "I will bc I'm the creator")
      assert {:ok, %{content: content}} = Room.get_event(room_id, account.user_id, event_id)
      assert 0 = map_size(content)
    end

    test "does not apply a redaction against another user if the redactor does not have 'redact' power", %{
      account: account,
      room_id: room_id
    } do
      rando = Fixtures.create_account()
      {:ok, _event_id} = Room.invite(room_id, account.user_id, rando.user_id)
      {:ok, _event_id} = Room.join(room_id, rando.user_id)

      {:ok, event_id} = Room.send_text_message(room_id, account.user_id, "try to delete me")

      assert {:ok, _redaction_event_id} = Room.redact_event(room_id, rando.user_id, event_id, "I can try")
      assert {:ok, %{content: %{"body" => "try to delete me"}}} = Room.get_event(room_id, account.user_id, event_id)
    end

    test "rejects an unauthorized redactor (does not have 'events -> m.room.redaction' power)", %{account: account} do
      {:ok, room_id} = Room.create(account.user_id, power_levels: %{"events" => %{"m.room.redaction" => 5}})

      rando = Fixtures.create_account()
      {:ok, _event_id} = Room.invite(room_id, account.user_id, rando.user_id)
      {:ok, _event_id} = Room.join(room_id, rando.user_id)

      {:ok, event_id} = Room.send_text_message(room_id, rando.user_id, "rando's message")

      assert {:error, :unauthorized} =
               Room.redact_event(room_id, rando.user_id, event_id, "can I delete my own msg? no")
    end
  end

  describe "get_members/4" do
    setup do
      account1 = Fixtures.create_account()
      account2 = Fixtures.create_account()
      account3 = Fixtures.create_account()

      %{account1: account1, account2: account2, account3: account3}
    end

    test "returns members when the requester is in the room", %{
      account1: creator,
      account2: account2,
      account3: account3
    } do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account3.user_id)
      {:ok, _event_id} = Room.join(room_id, account2.user_id)
      {:ok, _event_id} = Room.join(room_id, account3.user_id)

      assert {:ok, members} = Room.get_members(room_id, account2.user_id)
      assert 3 = Enum.count(members)
    end

    test "returns unauthorized when requester is not and has never been in the room", %{
      account1: creator,
      account2: account2,
      account3: account3
    } do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account3.user_id)
      {:ok, _event_id} = Room.join(room_id, account3.user_id)

      assert {:error, :unauthorized} = Room.get_members(room_id, account2.user_id)
    end

    test "returns members when the requester was last in the room after leaving", %{
      account1: creator,
      account2: account2,
      account3: account3
    } do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account3.user_id)
      {:ok, _event_id} = Room.join(room_id, account2.user_id)
      {:ok, _event_id} = Room.join(room_id, account3.user_id)
      {:ok, _event_id} = Room.leave(room_id, account2.user_id)

      assert {:ok, expected} = Room.get_members(room_id, account2.user_id)

      {:ok, _event_id} = Room.leave(room_id, account3.user_id)

      assert {:ok, actual} = Room.get_members(room_id, account2.user_id)
      assert Enum.sort(expected) == Enum.sort(actual)
    end

    test "returns members that pass the given filter", %{
      account1: creator,
      account2: account2,
      account3: account3
    } do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account3.user_id)
      {:ok, _event_id} = Room.join(room_id, account2.user_id)

      filter_fn = fn membership -> membership == "join" end
      assert {:ok, members} = Room.get_members(room_id, account2.user_id, :latest_visible, filter_fn)
      assert 2 = Enum.count(members)

      {:ok, _event_id} = Room.join(room_id, account3.user_id)

      assert {:ok, members} = Room.get_members(room_id, account2.user_id, :latest_visible, filter_fn)
      assert 3 = Enum.count(members)

      {:ok, _event_id} = Room.leave(room_id, account3.user_id)

      assert {:ok, members} = Room.get_members(room_id, account2.user_id, :latest_visible, filter_fn)
      assert 2 = Enum.count(members)
    end

    test "returns members in the room at the given event ID", %{
      account1: creator,
      account2: account2,
      account3: account3
    } do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)
      {:ok, _event_id} = Room.join(room_id, account2.user_id)

      content = %{"msgtype" => "m.text", "body" => "hi"}
      {:ok, event_id} = Room.send(room_id, creator.user_id, "m.room.message", content)

      assert {:ok, members} = Room.get_members(room_id, account2.user_id, event_id)
      assert 2 = Enum.count(members)

      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account3.user_id)
      {:ok, _event_id} = Room.join(room_id, account3.user_id)

      assert {:ok, members} = Room.get_members(room_id, account2.user_id, :latest_visible)
      assert 3 = Enum.count(members)

      assert {:ok, members} = Room.get_members(room_id, account2.user_id, event_id)
      assert 2 = Enum.count(members)

      filter_fn = fn membership -> membership == "join" end

      assert {:ok, members} = Room.get_members(room_id, account2.user_id, :latest_visible, filter_fn)
      assert 3 = Enum.count(members)

      assert {:ok, members} = Room.get_members(room_id, account2.user_id, event_id, filter_fn)
      assert 2 = Enum.count(members)
    end
  end

  describe "get_state/2" do
    setup do
      account1 = Fixtures.create_account()
      account2 = Fixtures.create_account()

      %{account1: account1, account2: account2}
    end

    test "returns cur room state when the requester is in the room", %{account1: creator} do
      {:ok, room_id} = Room.create(creator.user_id)

      :pong = Room.Server.ping(room_id)

      assert {:ok, state_event_stream} = Room.get_state(room_id, creator.user_id)
      assert 6 = Enum.count(state_event_stream)
    end

    test "returns unauthorized when requester is not and has never been in the room", %{
      account1: creator,
      account2: account2
    } do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)

      assert {:error, :unauthorized} = Room.get_state(room_id, account2.user_id)
    end

    test "returns the room state at the time the requester left", %{
      account1: creator,
      account2: account2
    } do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)
      {:ok, _event_id} = Room.join(room_id, account2.user_id)

      assert {:ok, state_event_stream} = Room.get_state(room_id, account2.user_id)
      assert 7 = Enum.count(state_event_stream)

      {:ok, _event_id} = Room.leave(room_id, account2.user_id)

      assert {:ok, state_event_stream_after_leave} = Room.get_state(room_id, account2.user_id)

      assert state_event_stream_after_leave
             |> Stream.reject(&(&1.type == "m.room.member" and &1.state_key == account2.user_id))
             |> Enum.sort() ==
               state_event_stream
               |> Stream.reject(&(&1.type == "m.room.member" and &1.state_key == account2.user_id))
               |> Enum.sort()

      {:ok, _event_id} = Room.set_name(room_id, creator.user_id, "A New Name")

      assert {:ok, state_event_stream_after_name} = Room.get_state(room_id, account2.user_id)
      assert Enum.sort(state_event_stream_after_name) == Enum.sort(state_event_stream_after_leave)
    end
  end

  describe "get_state/4" do
    setup do
      account1 = Fixtures.create_account()
      account2 = Fixtures.create_account()

      %{account1: account1, account2: account2}
    end

    test "returns state content when the requester is in the room", %{account1: creator} do
      {:ok, room_id} = Room.create(creator.user_id)

      :pong = Room.Server.ping(room_id)

      assert {:ok, %{content: %{"membership" => "join"}}} =
               Room.get_state(room_id, creator.user_id, "m.room.member", creator.user_id)
    end

    test "returns unauthorized when requester is not and has never been in the room", %{
      account1: creator,
      account2: account2
    } do
      {:ok, room_id} = Room.create(creator.user_id)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)

      assert {:error, :unauthorized} = Room.get_state(room_id, account2.user_id, "m.room.member", account2.user_id)
    end

    test "returns not_found when the key doesn't exist in the state", %{account1: creator} do
      {:ok, room_id} = Room.create(creator.user_id)
      assert {:error, :not_found} = Room.get_state(room_id, creator.user_id, "m.room.message_board", "")
    end

    test "returns the state content at the time the requester left", %{
      account1: creator,
      account2: account2
    } do
      topic = "There are monsters on this world"
      {:ok, room_id} = Room.create(creator.user_id, topic: topic)
      {:ok, _event_id} = Room.invite(room_id, creator.user_id, account2.user_id)
      {:ok, _event_id} = Room.join(room_id, account2.user_id)

      assert {:ok, %{content: %{"topic" => ^topic}} = event} =
               Room.get_state(room_id, account2.user_id, "m.room.topic", "")

      assert {:error, :not_found} = Room.get_state(room_id, account2.user_id, "m.room.name", "")

      {:ok, _event_id} = Room.leave(room_id, account2.user_id)
      {:ok, _event_id} = Room.set_name(room_id, creator.user_id, "A New Name")

      {:ok, _event_id} =
        Room.put_state(room_id, creator.user_id, "m.room.topic", %{"topic" => "THERE ARE MONSTERS ON THIS WORLD!?"})

      assert {:ok, ^event} = Room.get_state(room_id, account2.user_id, "m.room.topic", "")
      assert {:error, :not_found} = Room.get_state(room_id, account2.user_id, "m.room.name", "")
    end
  end

  describe "get_children/4,5" do
    setup do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id, addl_state_events: [history_visibility_event("joined")])
      {:ok, parent_id} = Room.send_text_message(room_id, creator_id, "a new room!")

      {:ok, eid1} = Room.send(room_id, creator_id, "m.room.message", relates_to(parent_id, "hello"))
      {:ok, eid2} = Room.send(room_id, creator_id, "m.room.message", relates_to(parent_id, "hello?"))
      {:ok, eid3} = Room.send(room_id, creator_id, "m.room.message", relates_to(parent_id, "anyone out there?"))
      {:ok, eid4} = Room.send(room_id, creator_id, "m.room.message", relates_to(parent_id, "guess I'm all alone"))
      {:ok, eid5} = Room.send(room_id, creator_id, "m.room.message", relates_to(parent_id, "I'll just talk to myself"))
      {:ok, eid6} = Room.send(room_id, creator_id, "m.room.message", relates_to(parent_id, "..."))

      %{
        creator_id: creator_id,
        room_id: room_id,
        parent_id: parent_id,
        eid1: eid1,
        eid2: eid2,
        eid3: eid3,
        eid4: eid4,
        eid5: eid5,
        eid6: eid6
      }
    end

    test "returns events as long as they are topologically greater than :to", %{
      creator_id: creator_id,
      room_id: room_id,
      parent_id: parent_id,
      eid1: eid1,
      eid2: eid2,
      eid3: eid3,
      eid4: eid4,
      eid5: eid5,
      eid6: eid6
    } do
      assert {:ok, [%{id: ^eid1}, %{id: ^eid2}, %{id: ^eid3}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, to: parent_id, order: :chronological)

      assert {:ok, [%{id: ^eid2}, %{id: ^eid3}, %{id: ^eid4}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, to: eid1, order: :chronological)

      assert {:ok, [%{id: ^eid4}, %{id: ^eid5}, %{id: ^eid6}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, to: eid3, order: :chronological)

      assert {:ok, [%{id: ^eid6}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, to: eid5, order: :chronological)

      assert {:ok, [%{id: ^eid6}, %{id: ^eid5}, %{id: ^eid4}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, to: parent_id, order: :reverse_chronological)

      assert {:ok, [%{id: ^eid6}, %{id: ^eid5}, %{id: ^eid4}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, to: eid1, order: :reverse_chronological)

      assert {:ok, [%{id: ^eid6}, %{id: ^eid5}, %{id: ^eid4}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, to: eid3, order: :reverse_chronological)

      assert {:ok, [%{id: ^eid6}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, to: eid5, order: :reverse_chronological)
    end

    test "returns events as long as they are topologically less than :from", %{
      creator_id: creator_id,
      room_id: room_id,
      parent_id: parent_id,
      eid1: eid1,
      eid2: eid2,
      eid3: eid3,
      eid4: eid4,
      eid5: eid5
    } do
      assert {:ok, [], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: parent_id, order: :chronological)

      assert {:ok, [], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: eid1, order: :chronological)

      assert {:ok, [%{id: ^eid1}, %{id: ^eid2}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: eid3, order: :chronological)

      assert {:ok, [%{id: ^eid1}, %{id: ^eid2}, %{id: ^eid3}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: eid5, order: :chronological)

      assert {:ok, [], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: parent_id, order: :reverse_chronological)

      assert {:ok, [], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: eid1, order: :reverse_chronological)

      assert {:ok, [%{id: ^eid2}, %{id: ^eid1}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: eid3, order: :reverse_chronological)

      assert {:ok, [%{id: ^eid4}, %{id: ^eid3}, %{id: ^eid2}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: eid5, order: :reverse_chronological)
    end

    test "returns events as long as they are topologically within the bounds of :from and :to", %{
      creator_id: creator_id,
      room_id: room_id,
      parent_id: parent_id,
      eid1: eid1,
      eid2: eid2,
      eid3: eid3,
      eid4: eid4,
      eid5: eid5
    } do
      assert {:ok, [%{id: ^eid1}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: eid2, to: parent_id, order: :chronological)

      assert {:ok, [%{id: ^eid1}, %{id: ^eid2}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: eid3, to: parent_id, order: :chronological)

      assert {:ok, [%{id: ^eid2}, %{id: ^eid1}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3,
                 from: eid3,
                 to: parent_id,
                 order: :reverse_chronological
               )

      assert {:ok, [%{id: ^eid4}, %{id: ^eid3}, %{id: ^eid2}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3,
                 from: eid5,
                 to: parent_id,
                 order: :reverse_chronological
               )

      assert {:ok, [%{id: ^eid1}, %{id: ^eid2}, %{id: ^eid3}], 1} =
               Room.get_children(room_id, creator_id, parent_id, 3, from: eid5, to: parent_id, order: :chronological)
    end

    test "a user can't fetch child events that history visibility doesn't allow them to see", %{
      creator_id: creator_id,
      room_id: room_id
    } do
      %{user_id: user_id} = Fixtures.create_account()
      {:ok, _event_id} = Room.invite(room_id, creator_id, user_id)
      {:ok, _event_id} = Room.join(room_id, user_id)

      {:ok, parent_id} = Room.send_text_message(room_id, creator_id, "omgggg")
      {:ok, eid1} = Room.send(room_id, creator_id, "m.room.message", relates_to(parent_id, "hello friend!"))

      {:ok, _event_id} = Room.leave(room_id, user_id)

      {:ok, _eid2_user_cant_see} =
        Room.send(room_id, creator_id, "m.room.message", relates_to(parent_id, "oh...bye...friend"))

      {:ok, eid3} = Room.send(room_id, creator_id, "m.room.message", relates_to(parent_id, ":("))

      assert {:ok, [%{id: ^eid1}], 1} =
               Room.get_children(room_id, user_id, parent_id, 3, from: eid3, order: :chronological)
    end
  end

  defp history_visibility_event(visibility) do
    %{
      "content" => %{"history_visibility" => visibility},
      "state_key" => "",
      "type" => "m.room.history_visibility"
    }
  end

  defp relates_to(parent_id, msg) do
    %{
      "msgtype" => "m.text",
      "body" => msg,
      "m.relates_to" => %{
        "rel_type" => "m.thread",
        "event_id" => parent_id
      }
    }
  end
end
