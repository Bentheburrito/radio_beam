defmodule RadioBeam.User.EventFilterTest do
  use ExUnit.Case, async: true
  doctest RadioBeam.User.EventFilter

  alias RadioBeam.User.EventFilter

  describe "new/1" do
    @room_ids Enum.map(1..6, fn _ -> RadioBeam.Room.generate_id() end)
              |> Enum.chunk_every(2)
              |> List.duplicate(2)
              |> Enum.flat_map(& &1)
              |> Enum.shuffle()

    defp random_bool, do: Enum.random([true, false])

    test "parses a raw Filter Matrix spec definition into an EventFilter" do
      for format <- ~w|client federation invalid_fmt|,
          fields <- [["content.body", "type"], :none],
          include_leave? <- [true, false],
          rooms_ids <- @room_ids,
          not_rooms_ids <- @room_ids,
          limit <- [0, RadioBeam.max_timeline_events(), RadioBeam.max_timeline_events() + 1] do
        timeline = %{
          "contains_url" => random_bool(),
          "include_redundant_members" => random_bool(),
          "lazy_load_members" => random_bool(),
          "limit" => limit,
          "rooms" => Enum.random(@room_ids),
          "not_rooms" => Enum.random(@room_ids),
          # TODO: add some actual data here to assert against...
          "senders" => [],
          "not_senders" => [],
          "types" => [],
          "not_types" => []
        }

        filter_defintion = %{
          "event_format" => format,
          "room" => %{
            "rooms" => rooms_ids,
            "not_rooms" => not_rooms_ids,
            "include_leave" => include_leave?,
            "timeline" => timeline
          }
        }

        filter_defintion =
          if fields == :none, do: filter_defintion, else: Map.put(filter_defintion, "event_fields", fields)

        assert %EventFilter{
                 fields: parsed_fields,
                 format: format,
                 id: id,
                 include_leave?: ^include_leave?,
                 raw_definition: ^filter_defintion,
                 rooms: rooms_filter_list,
                 state: %{},
                 timeline: parsed_timeline
               } = EventFilter.new(filter_defintion)

        if fields == :none, do: assert(is_nil(parsed_fields)), else: assert(parsed_fields == fields)

        assert format in ~w|client federation|
        assert is_binary(id)

        case rooms_filter_list do
          {:allowlist, allowed_room_ids} -> assert lists_equal?(allowed_room_ids, rooms_ids -- not_rooms_ids)
          {:denylist, disallowed_room_ids} -> assert lists_equal?(disallowed_room_ids, not_rooms_ids)
        end

        assert timeline["contains_url"] == parsed_timeline.contains_url

        case parsed_timeline.memberships do
          :lazy_redundant -> assert timeline["lazy_load_members"] and timeline["include_redundant_members"]
          :lazy -> assert timeline["lazy_load_members"] and not timeline["include_redundant_members"]
          :all -> assert not timeline["lazy_load_members"]
        end

        assert parsed_timeline.limit in 1..RadioBeam.max_timeline_events()

        assert parsed_timeline.senders == :none
        assert parsed_timeline.types == :none

        case parsed_timeline.rooms do
          {:allowlist, allowed_room_ids} ->
            assert lists_equal?(allowed_room_ids, timeline["rooms"] -- timeline["not_rooms"])

          {:denylist, disallowed_room_ids} ->
            assert lists_equal?(disallowed_room_ids, timeline["not_rooms"])
        end
      end
    end
  end

  # TODO: move to helpers/support module
  defp lists_equal?(l1, l2), do: Enum.sort(l1) == Enum.sort(l2)

  describe "both allow_timeline_event?/2 and allow_state_event?/4" do
    test "correctly applies the `contains_url` filter" do
      non_url_content = %{"body" => "I'm done. Do what you want. Pull the plug", "msgtype" => "m.text"}

      for contains_url <- [:none, true, false], content <- [non_url_content, %{"url" => "some.url"}] do
        expected =
          case {contains_url, is_map_key(content, "url")} do
            {:none, _} -> true
            {contains_url, url_key?} -> not (contains_url != url_key?)
          end

        filter =
          EventFilter.new(%{
            "room" => %{
              "timeline" => %{"contains_url" => contains_url},
              "state" => %{"contains_url" => contains_url}
            }
          })

        assert expected == EventFilter.allow_timeline_event?(filter, %{type: "", sender: "", content: content})
        assert expected == EventFilter.allow_state_event?(filter, %{type: "", sender: "", content: content}, [], [])
      end
    end

    test "correctly applies the `senders` filter" do
      senders = ["@danflashes:localhost", "@doug:localhost", "@egg:localhost"]

      for i <- 0..length(senders),
          sender <- ["whomegalol@localhost" | senders] do
        {allowed, denied} = Enum.split(senders, i)
        raw_senders = %{"senders" => allowed, "not_senders" => denied}

        filter = EventFilter.new(%{"room" => %{"timeline" => raw_senders, "state" => raw_senders}})

        expected =
          case {filter.timeline.senders, sender} do
            {{:allowlist, allowed}, sender} -> sender in allowed
            {{:denylist, denied}, sender} -> sender not in denied
            {:none, _sender} -> true
          end

        assert expected == EventFilter.allow_timeline_event?(filter, %{type: "", sender: sender, content: %{}})
        assert expected == EventFilter.allow_state_event?(filter, %{type: "", sender: sender, content: %{}}, [], [])
      end
    end

    test "correctly applies the `types` filter" do
      types = ["m.room.member", "m.room.message", "m.room.topic"]

      for i <- 0..length(types),
          type <- ["m.room.power_levels" | types] do
        {allowed, denied} = Enum.split(types, i)
        raw_types = %{"types" => allowed, "not_types" => denied}

        filter = EventFilter.new(%{"room" => %{"timeline" => raw_types, "state" => raw_types}})

        expected =
          case {filter.timeline.types, type} do
            {{:allowlist, allowed}, type} -> type in allowed
            {{:denylist, denied}, type} -> type not in denied
            {:none, _type} -> true
          end

        assert expected == EventFilter.allow_timeline_event?(filter, %{type: type, sender: "", content: %{}})
        assert expected == EventFilter.allow_state_event?(filter, %{type: type, sender: "", content: %{}}, [], [])
      end
    end
  end

  describe "allow_state_event?/4 when state.memberships == :lazy" do
    @filter EventFilter.new(%{
              "room" => %{"state" => %{"lazy_load_members" => true, "include_redundant_members" => false}}
            })
    test "returns `false` when a membership event is already known to the user, regardless of whether they've sent an event included in the timeline" do
      user = "@helloitsme:localhost"
      membership_event = %{type: "m.room.member", state_key: user, content: %{}, sender: user}

      assert @filter.state.memberships == :lazy

      for senders <- [[user], []] do
        refute EventFilter.allow_state_event?(@filter, membership_event, senders, [user])
      end
    end

    test "returns `false` when a membership event is not a sender of an event in the timeline, regardless of the known memberships" do
      user = "@helloitsme:localhost"
      membership_event = %{type: "m.room.member", state_key: user, content: %{}, sender: user}

      assert @filter.state.memberships == :lazy

      for known_members <- [[user], []] do
        refute EventFilter.allow_state_event?(@filter, membership_event, [], known_members)
      end
    end

    test "returns `true` when a membership event is a sender of an event in the timeline, and their memberships is not already known" do
      user = "@helloitsme:localhost"
      membership_event = %{type: "", state_key: user, content: %{}, sender: user}

      assert @filter.state.memberships == :lazy

      assert EventFilter.allow_state_event?(@filter, membership_event, [user], [])
    end
  end

  describe "allow_state_event?/4 when state.memberships == :lazy_redundant" do
    @filter EventFilter.new(%{
              "room" => %{"state" => %{"lazy_load_members" => true, "include_redundant_members" => true}}
            })

    test "returns `false` when a membership event is not a sender of an event in the timeline, regardless of the known memberships" do
      user = "@helloitsme:localhost"
      membership_event = %{type: "m.room.member", state_key: user, content: %{}, sender: user}

      assert @filter.state.memberships == :lazy_redundant

      for known_members <- [[user], []] do
        refute EventFilter.allow_state_event?(@filter, membership_event, [], known_members)
      end
    end

    test "returns `true` when a membership event is a sender of an event in the timeline, regardless of whether their membership is already known" do
      user = "@helloitsme:localhost"
      membership_event = %{type: "", state_key: user, content: %{}, sender: user}

      assert @filter.state.memberships == :lazy_redundant

      for known_members <- [[user], []] do
        assert EventFilter.allow_state_event?(@filter, membership_event, [user], known_members)
      end
    end
  end

  describe "allow_state_event?/4 when state.memberships == :all" do
    @raw_filter %{"room" => %{"state" => %{}}}

    test "returns `true` regardless of senders and known memberships" do
      user = "@helloitsme:localhost"
      membership_event = %{type: "m.room.member", state_key: user, content: %{}, sender: user}

      for raw_filter <- [@raw_filter, put_in(@raw_filter["room"]["state"]["lazy_load_members"], false)],
          senders <- [[user], []],
          known_members <- [[user], []] do
        filter = EventFilter.new(raw_filter)
        assert filter.state.memberships == :all
        assert EventFilter.allow_state_event?(filter, membership_event, senders, known_members)
      end
    end
  end
end
