defmodule RadioBeam.Room.Timeline.CoreTest do
  use ExUnit.Case, async: true
  alias RadioBeam.Room.Timeline.Core
  alias RadioBeam.User.EventFilter
  doctest Core

  describe "passes_filter?/2" do
    setup do
      %{default_filter: EventFilter.new(%{}).timeline}
    end

    test "correctly applies the `contains_url` filter", %{default_filter: f} do
      non_url_content = %{"body" => "I'm done. Do what you want. Pull the plug", "msgtype" => "m.text"}

      for contains_url <- [:none, true, false], content <- [non_url_content, %{"url" => "some.url"}] do
        expected =
          case {contains_url, is_map_key(content, "url")} do
            {:none, _} -> true
            {contains_url, url_key?} -> not (contains_url != url_key?)
          end

        assert expected ==
                 Core.passes_filter?(%{f | contains_url: contains_url}, %{type: "", sender: "", content: content})
      end
    end

    test "correctly applies the `senders` filter", %{default_filter: f} do
      senders = ["@danflashes:localhost", "@doug:localhost", "@egg:localhost"]
      {allowed, denied} = Enum.split(senders, Enum.random(0..length(senders)))

      sender_filters = [
        {:allowlist, allowed},
        {:denylist, denied},
        :none
      ]

      for sender_filter <- sender_filters,
          sender <- ["@danflashes:localhost", "@doug:localhost", "@egg:localhost", "whomegalol@localhost"] do
        expected =
          case {sender_filter, sender} do
            {{:allowlist, allowed}, sender} -> sender in allowed
            {{:denylist, denied}, sender} -> sender not in denied
            {:none, _sender} -> true
          end

        assert expected == Core.passes_filter?(%{f | senders: sender_filter}, %{type: "", sender: sender, content: %{}})
      end
    end

    test "correctly applies the `types` filter", %{default_filter: f} do
      types = ["m.room.member", "m.room.message", "m.room.topic"]
      {allowed, denied} = Enum.split(types, Enum.random(0..length(types)))

      type_filters = [
        {:allowlist, allowed},
        {:denylist, denied},
        :none
      ]

      for type_filter <- type_filters,
          type <- ["m.room.member", "m.room.message", "m.room.topic", "m.room.power_levels"] do
        expected =
          case {type_filter, type} do
            {{:allowlist, allowed}, type} -> type in allowed
            {{:denylist, denied}, type} -> type not in denied
            {:none, _type} -> true
          end

        assert expected == Core.passes_filter?(%{f | types: type_filter}, %{type: type, sender: "", content: %{}})
      end
    end
  end
end
