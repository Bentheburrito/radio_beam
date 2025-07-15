defmodule RadioBeam.Room.Timeline.CoreTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.EventFilter
  alias RadioBeam.PDU
  alias RadioBeam.Room.Timeline.Core

  describe "user_joined_later?/2" do
    test "returns `true` if the given user's latest known join PDU is later than the given PDU" do
      pdu = %PDU{chunk: 0, depth: 0}
      latest_known_join = %PDU{chunk: 0, depth: 1}
      assert Core.user_joined_later?(pdu, latest_known_join)
    end

    test "returns `false` if the given user's latest known join PDU is earlier or equal to the given PDU" do
      pdu = %PDU{chunk: 0, depth: 1}
      latest_known_join = %PDU{chunk: 0, depth: 0}
      refute Core.user_joined_later?(pdu, latest_known_join)

      latest_known_join = pdu
      refute Core.user_joined_later?(pdu, latest_known_join)
    end
  end

  describe "user_authorized_to_view?/4" do
    @user_id "@arandomfellow:localhost"
    test "always returns `true` when history visibility at the PDU is `world_readable`" do
      for membership_at_pdu <- ~w|leave invite join|,
          joined_later? <- ~w|true false|a,
          pdu <- pdus_with_current_vis("world_readable", @user_id) do
        membership_at_pdu = pdu.content["membership"] || membership_at_pdu
        assert Core.user_authorized_to_view?(pdu, @user_id, membership_at_pdu, joined_later?)
      end
    end

    test "returns `true` when the user is joined at the time the PDU was sent" do
      membership_at_pdu = "join"

      for current_vis <- ~w|world_readable joined shared invited|,
          joined_later? <- ~w|true false|a,
          pdu <- pdus_with_current_vis(current_vis, @user_id) do
        assert Core.user_authorized_to_view?(pdu, @user_id, membership_at_pdu, joined_later?)
      end
    end

    test "returns `true` when the user was NOT joined at the time the PDU was sent, but the history visibility when the PDU was sent was `shared`, and the user joined later" do
      joined_later? = true

      for membership_at_pdu <- ~w|leave invite|,
          pdu <- pdus_with_current_vis("shared", @user_id),
          pdu.content["membership"] != "join" and pdu.unsigned["prev_content"]["membership"] != "join" do
        membership_at_pdu = pdu.content["membership"] || membership_at_pdu
        assert Core.user_authorized_to_view?(pdu, @user_id, membership_at_pdu, joined_later?)
      end
    end

    test "returns `false` when the user was NOT joined at the time the PDU was sent, and the history visibility when the PDU was sent was `joined`, even though the user joined later" do
      joined_later? = true

      for membership_at_pdu <- ~w|leave invite| do
        pdu = %PDU{type: "m.room.message", current_visibility: "joined"}
        refute Core.user_authorized_to_view?(pdu, @user_id, membership_at_pdu, joined_later?)
      end
    end

    test "returns `true` if the user was invited at the time the PDU was sent, and the history visibility when the PDU was sent was `invited` AND the user joined later" do
      for joined_later? <- ~w|true false|a do
        membership_at_pdu = "invite"
        pdu = %PDU{type: "m.room.message", current_visibility: "invited"}

        assert joined_later? == Core.user_authorized_to_view?(pdu, @user_id, membership_at_pdu, joined_later?)
      end
    end

    test "returns `false` if the user was not joined at the time the PDU was sent nor later, unless the PDU is a history_visibility event that would allow it under the new visibiility rule" do
      joined_later? = false

      for membership_at_pdu <- ~w|leave invite|,
          pdu <- pdus_with_current_vis("joined", @user_id),
          pdu.content["membership"] != "join" and pdu.unsigned["prev_content"]["membership"] != "join" do
        membership_at_pdu = pdu.content["membership"] || membership_at_pdu

        pdu_newly_visible? =
          pdu.type == "m.room.history_visibility" and pdu.content["history_visibility"] == "world_readable"

        assert pdu_newly_visible? == Core.user_authorized_to_view?(pdu, @user_id, membership_at_pdu, joined_later?)
      end
    end

    test "returns `false` if the user was not joined at the time the PDU was sent nor later, unless the PDU is their member event that serves as the last visible event" do
      joined_later? = false

      for pdu <- pdus_with_current_vis("joined", @user_id),
          pdu.content["membership"] != "join" and pdu.content["history_visibility"] != "world_readable" and
            pdu.unsigned["prev_content"]["membership"] == "join" do
        pdu_is_non_join_member? = pdu.type == "m.room.member"

        assert pdu_is_non_join_member? == Core.user_authorized_to_view?(pdu, @user_id, "leave", joined_later?)
      end
    end

    test "returns `false` if the user was never a member of the (non-world_readable) room" do
      joined_later? = false

      for visibility <- ~w|joined shared invited|,
          pdu <- pdus_with_current_vis(visibility, @user_id),
          membership_at_pdu <- ~w|leave kick ban|,
          pdu.content["history_visibility"] != "world_readable" and pdu.content["membership"] != "join" and
            pdu.unsigned["prev_content"]["membership"] != "join" do
        refute Core.user_authorized_to_view?(pdu, @user_id, membership_at_pdu, joined_later?)
      end
    end

    defp pdus_with_current_vis(current_visibility, user_id) do
      history_vis_pdus =
        for visibility <- ~w|world_readable joined shared invited| do
          %PDU{type: "m.room.history_visibility", content: %{"history_visibility" => visibility}}
        end

      membership_pdus =
        for membership <- ~w|leave invite join|,
            prev_membership <- ~w|leave invite join|,
            not (prev_membership == "join" and membership == "invite") do
          %PDU{
            type: "m.room.member",
            state_key: user_id,
            content: %{"membership" => membership},
            unsigned: %{"prev_content" => %{"membership" => prev_membership}}
          }
        end

      for pdu <- history_vis_pdus ++ membership_pdus ++ [%PDU{type: "m.room.message"}] do
        put_in(pdu.current_visibility, current_visibility)
      end
    end
  end

  describe "from_event_stream/7" do
    @user_id "@someone:localhost"
    @annoying_id "@annoying:localhost"
    @first_visible_events [
      %PDU{type: "m.room.message", content: %{"body" => "hello world"}, current_visibility: "joined"},
      %PDU{
        type: "m.room.message",
        content: %{"body" => "hello world 2"},
        sender: @annoying_id,
        current_visibility: "joined"
      },
      %PDU{
        type: "m.room.member",
        state_key: @user_id,
        content: %{"membership" => "leave"},
        unsigned: %{"prev_content" => %{"membership" => "join"}},
        current_visibility: "joined"
      }
    ]

    @not_visible_events [
      %PDU{type: "m.room.message", content: %{"body" => "can't see me"}, current_visibility: "joined"},
      %PDU{type: "m.room.message", content: %{"body" => "can't see this either"}, current_visibility: "joined"}
    ]

    @second_visible_events [
      %PDU{
        type: "m.room.member",
        state_key: @user_id,
        content: %{"membership" => "join"},
        current_visibility: "joined",
        unsigned: %{"prev_content" => %{"membership" => "leave"}}
      },
      %PDU{type: "m.room.message", content: %{"body" => "we're so back"}, current_visibility: "joined"}
    ]

    test "filters the given event_stream by visible events, for both directions" do
      event_stream = Stream.concat([@first_visible_events, @not_visible_events, @second_visible_events])
      direction = :forward
      latest_known_join = hd(@second_visible_events)
      filter = EventFilter.new(%{})
      ignored_user_ids = []

      assert @first_visible_events ++ @second_visible_events ==
               event_stream
               |> Core.from_event_stream(direction, @user_id, "join", latest_known_join, filter, ignored_user_ids)
               |> Enum.to_list()

      direction = :backward

      assert Enum.reverse(@first_visible_events ++ @second_visible_events) ==
               Enum.reverse(event_stream)
               |> Core.from_event_stream(direction, @user_id, "join", latest_known_join, filter, ignored_user_ids)
               |> Enum.to_list()
    end

    test "rejects events sent by ignored users in the given event_stream, for both directions" do
      event_stream = Stream.concat([@first_visible_events, @not_visible_events, @second_visible_events])
      direction = :forward
      latest_known_join = hd(@second_visible_events)
      filter = EventFilter.new(%{})
      ignored_user_ids = [@annoying_id]

      first_without_annoying_user = Enum.reject(@first_visible_events, &(&1.sender == @annoying_id))

      assert first_without_annoying_user ++ @second_visible_events ==
               event_stream
               |> Core.from_event_stream(direction, @user_id, "join", latest_known_join, filter, ignored_user_ids)
               |> Enum.to_list()

      direction = :backward

      assert Enum.reverse(first_without_annoying_user ++ @second_visible_events) ==
               Enum.reverse(event_stream)
               |> Core.from_event_stream(direction, @user_id, "join", latest_known_join, filter, ignored_user_ids)
               |> Enum.to_list()
    end

    test "rejects events in the given event_stream that don't pass the given filter, for both directions" do
      event_stream = Stream.concat([@first_visible_events, @not_visible_events, @second_visible_events])
      direction = :forward
      latest_known_join = hd(@second_visible_events)
      filter = EventFilter.new(%{"room" => %{"timeline" => %{"not_types" => ["m.room.message"]}}})
      ignored_user_ids = []

      expected_stream = Enum.reject(@first_visible_events ++ @second_visible_events, &(&1.type == "m.room.message"))

      assert expected_stream ==
               event_stream
               |> Core.from_event_stream(direction, @user_id, "join", latest_known_join, filter, ignored_user_ids)
               |> Enum.to_list()

      direction = :backward

      assert Enum.reverse(expected_stream) ==
               Enum.reverse(event_stream)
               |> Core.from_event_stream(direction, @user_id, "join", latest_known_join, filter, ignored_user_ids)
               |> Enum.to_list()
    end
  end
end
