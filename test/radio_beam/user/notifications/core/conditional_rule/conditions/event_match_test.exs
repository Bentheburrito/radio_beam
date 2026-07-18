defmodule RadioBeam.User.Notifications.Core.ConditionalRule.Conditions.EventMatchTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.View.Core.Timeline
  alias RadioBeam.User.Notifications.Core.ConditionalRule.Conditions.EventMatch

  setup do
    %{user_id: user_id} = Fixtures.create_account()

    {:sent, room, message_id, _} =
      "12" |> Fixtures.room(user_id) |> Fixtures.send_room_msg(user_id, "Hello world, this is a message.")

    timeline = Fixtures.make_room_view(Timeline, room)

    [message_event] =
      Timeline.get_visible_events(timeline, [message_id], user_id, &Room.Chronicle.fetch_pdu!(room.chronicle, &1))
      |> Enum.to_list()

    %{room: room, timeline: timeline, user_id: user_id, message_event: message_event}
  end

  describe "new/2 returns a predicate that" do
    test "returns `true` when the given string property exactly matches", %{
      user_id: user_id,
      message_event: message_event
    } do
      {:ok, predicate} = EventMatch.new("type", "m.room.message")
      assert predicate.(message_event)

      {:ok, predicate} = EventMatch.new("sender", user_id)
      assert predicate.(message_event)
    end

    test "returns `false` when the given string property does not match", %{
      user_id: user_id,
      message_event: message_event
    } do
      {:ok, predicate} = EventMatch.new("type", "m.room.topic")
      refute predicate.(message_event)

      {:ok, predicate} = EventMatch.new("state_key", user_id)
      refute predicate.(message_event)

      {:ok, predicate} = EventMatch.new("unknown_property", "abcde")
      refute predicate.(message_event)
    end

    test "returns `true` when the given string property partially matches", %{user_id: user_id, room: room} do
      for length <- 0..100, value <- [Fixtures.random_string(length)], pattern <- matching_patterns(value) do
        {:sent, room, event_id, _} = Fixtures.send_room_event(room, user_id, "org.some.event", %{"value" => value})

        timeline = Fixtures.make_room_view(Timeline, room)

        [message_event] =
          Timeline.get_visible_events(timeline, [event_id], user_id, &Room.Chronicle.fetch_pdu!(room.chronicle, &1))
          |> Enum.to_list()

        {:ok, predicate} = EventMatch.new("content.value", pattern)
        assert predicate.(message_event)
      end
    end

    test "returns `false` when the given string property does not match with incompatible wildcards", %{
      user_id: user_id,
      room: room
    } do
      for length <- 0..100, value <- [Fixtures.random_string(length)], pattern <- nonmatching_patterns(value) do
        {:sent, room, event_id, _} = Fixtures.send_room_event(room, user_id, "org.some.event", %{"value" => value})

        timeline = Fixtures.make_room_view(Timeline, room)

        [message_event] =
          Timeline.get_visible_events(timeline, [event_id], user_id, &Room.Chronicle.fetch_pdu!(room.chronicle, &1))
          |> Enum.to_list()

        {:ok, predicate} = EventMatch.new("content.value", pattern)
        refute predicate.(message_event)
      end
    end
  end

  describe "new/2 with key content.body returns a predicate that" do
    test "returns `true` when the body matches across word boundaries", %{user_id: user_id, room: room} do
      for length <- 0..10,
          message_part <- [Fixtures.random_string(length)],
          pattern <- matching_patterns(message_part),
          String.trim(message_part) != "" do
        # puts message_part somewhere between 0..6 other random "words"
        message =
          0..3
          |> Stream.map(fn _i -> Fixtures.random_string(Enum.random(0..length)) end)
          |> Stream.concat([message_part])
          |> Stream.concat(0..3 |> Stream.map(fn _i -> Fixtures.random_string(Enum.random(0..length)) end))
          |> Enum.join(" ")

        {:sent, room, event_id, _} = Fixtures.send_room_msg(room, user_id, message)

        timeline = Fixtures.make_room_view(Timeline, room)

        [message_event] =
          Timeline.get_visible_events(timeline, [event_id], user_id, &Room.Chronicle.fetch_pdu!(room.chronicle, &1))
          |> Enum.to_list()

        {:ok, predicate} = EventMatch.new("content.body", pattern)
        assert predicate.(message_event)
      end
    end

    test "returns `false` when the body does not match, even across word boundaries", %{user_id: user_id, room: room} do
      for length <- 0..10,
          message_part <- [Fixtures.random_string(length)],
          pattern <- nonmatching_patterns(message_part),
          String.trim(message_part) != "" do
        # puts message_part somewhere between 0..6 other random "words"
        message =
          0..3
          |> Stream.map(fn _i -> Fixtures.random_string(Enum.random(0..length)) end)
          |> Stream.concat([message_part])
          |> Stream.concat(0..3 |> Stream.map(fn _i -> Fixtures.random_string(Enum.random(0..length)) end))
          |> Enum.join(" ")

        {:sent, room, event_id, _} = Fixtures.send_room_msg(room, user_id, message)

        timeline = Fixtures.make_room_view(Timeline, room)

        [message_event] =
          Timeline.get_visible_events(timeline, [event_id], user_id, &Room.Chronicle.fetch_pdu!(room.chronicle, &1))
          |> Enum.to_list()

        {:ok, predicate} = EventMatch.new("content.body", pattern)
        refute predicate.(message_event)
      end
    end
  end

  describe "new/2" do
    test "returns :invalid_key when given an property string" do
      assert {:error, :invalid_key} = EventMatch.new(123, "hello")
      assert {:error, :invalid_key} = EventMatch.new("yo" <> <<0>>, "hello")
      assert {:error, :invalid_key} = EventMatch.new("yo" <> <<0xFF::8>>, "hello")
    end

    test "returns :unreasonable_pattern when given a pattern with too many wildcards" do
      assert {:error, :unreasonable_pattern} = EventMatch.new("content.somefield", String.duplicate("?", 1000))
      assert {:error, :unreasonable_pattern} = EventMatch.new("content.somefield", String.duplicate("*", 1000))
      assert {:error, :unreasonable_pattern} = EventMatch.new("content.somefield", "abc" <> String.duplicate("*", 1000))
      assert {:error, :unreasonable_pattern} = EventMatch.new("content.somefield", "abc" <> String.duplicate("?", 1000))
    end
  end

  @wildcards ~w|? *|
  defp matching_patterns(value) do
    value_without_first = String.slice(value, 1..-1//1)
    value_without_last = String.slice(value, 0..-2//1)
    value_no_first_nor_last = String.slice(value_without_first, 0..-2//1)

    glob_patterns = [
      "*",
      value,
      "*" <> value,
      "*" <> value_without_first,
      value <> "*",
      value_without_last <> "*",
      "*" <> value <> "*",
      "*" <> value_no_first_nor_last <> "*"
    ]

    # since "?" is an exactly-one match, input strings of 0 or 1 need special-casing
    basic_patterns =
      case String.length(value) do
        l when l > 1 ->
          [
            "?" <> value_without_first,
            value_without_last <> "?",
            "?" <> value_no_first_nor_last <> "?",
            "?" <> value_no_first_nor_last <> "*",
            "*" <> value_no_first_nor_last <> "?"
            | glob_patterns
          ]

        l when l == 1 ->
          [
            "?" <> value_without_first,
            value_without_last <> "?",
            "?" <> value_no_first_nor_last <> "*",
            "*" <> value_no_first_nor_last <> "?"
            | glob_patterns
          ]

        l when l == 0 ->
          glob_patterns
      end

    basic_patterns ++
      for str <- basic_patterns, wildcard <- @wildcards, String.match?(str, ~r/[^?*]/) do
        to_replace = str |> String.graphemes() |> Stream.reject(&(&1 in @wildcards)) |> Enum.random()
        String.replace(str, to_replace, wildcard)
      end
  end

  defp nonmatching_patterns(value) do
    value_length = String.length(value)

    basic_nonmatching_patterns = [
      "extranonsense" <> value,
      value <> "extranonsense"
    ]

    basic_nonmatching_patterns ++
      for pattern <- matching_patterns(value),
          token <- ~w|aaaaaa ? 123123|,
          # we calculate the substr here, so we get a different one for each iteration
          substr_slice = Enum.random(0..div(value_length, 2))..Enum.random(div(value_length, 2)..value_length),
          substr = String.slice(value, substr_slice),
          fxn <- [&"#{token}#{&1}", &"#{&1}#{token}", &"#{token}#{&1}#{token}", &String.replace(&1, substr, token)],
          pattern != fxn.(pattern) and not edge_case?(value, pattern) and not edge_case?(value, fxn.(pattern)) do
        fxn.(pattern)
      end
  end

  # we generate some patterns that are still valid even after appending
  # additional tokens, namely simple wildcard-only patterns like "*?*", "?*",
  # and so on. This returns true if we have a pattern with only wilcards, and
  # the number of exactly-one wildcards (?) is <= the length of the value
  # (which would always match)
  defp edge_case?(value, pattern) do
    String.match?(pattern, ~r/[?*]+/) and String.count(pattern, "?") <= String.length(value)
  end
end
