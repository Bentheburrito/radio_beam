defmodule RadioBeam.Room.Timeline.FilterTest do
  use ExUnit.Case

  alias RadioBeam.Room.Timeline.Filter

  describe "apply/2" do
    test "can apply a URL filter" do
      room_id = "!corncobtv:localhost"
      sender = "@danielflashes:locahost"

      pairs = [
        {"m.room.avatar", %{"url" => "www.example.com/someavatar"}},
        {"m.room.name", %{"name" => "a name"}}
      ]

      for {type, content} <- pairs, contains_url? <- [true, false] do
        event_filter = %{"contains_url" => contains_url?}
        filter = %{"room" => %{"timeline" => event_filter, "state" => event_filter}}

        event = event(room_id, type, sender, content, "")

        case {is_map_key(content, "url"), contains_url?} do
          {true, true} -> assert ^event = Filter.apply(filter, event)
          {false, false} -> assert ^event = Filter.apply(filter, event)
          _ -> assert is_nil(Filter.apply(filter, event))
        end
      end
    end

    test "can apply senders and not_senders filters" do
      room_id = "!corncobtv:localhost"
      type = "m.room.message"
      content = %{"body" => "I'm done. Do what you want. Pull the plug", "msgtype" => "m.text"}

      event_filter = %{
        "senders" => ["@danflashes:localhost", "@egg:localhost"],
        "not_senders" => ["@egg:localhost"]
      }

      for sender <- ["@danflashes:localhost", "@doug:localhost", "@egg:localhost"] do
        filter = %{"room" => %{"timeline" => event_filter, "state" => event_filter}}
        event = event(room_id, type, sender, content)

        case sender do
          "@danflashes:localhost" -> assert ^event = Filter.apply(filter, event)
          "@doug:localhost" -> assert is_nil(Filter.apply(filter, event))
          "@egg:localhost" -> assert is_nil(Filter.apply(filter, event))
        end
      end
    end

    test "can apply types and not_types filters" do
      room_id = "!corncobtv:localhost"
      sender = "@danflahes:localhost"

      event_filter = %{
        "types" => ["m.room.topic", "m.room.name"],
        "not_types" => ["m.room.name"]
      }

      for type <- ["m.room.topic", "m.room.name", "m.room.canonical_alias"] do
        filter = %{"room" => %{"timeline" => event_filter, "state" => event_filter}}
        event = event(room_id, type, sender, %{}, "")

        case type do
          "m.room.topic" -> assert ^event = Filter.apply(filter, event)
          "m.room.name" -> assert is_nil(Filter.apply(filter, event))
          "m.room.canonical_alias" -> assert is_nil(Filter.apply(filter, event))
        end
      end
    end
  end

  describe "apply_rooms/2" do
    test "can apply rooms and not_rooms filters against a list of room_ids" do
      room_ids = Enum.map(1..10, fn _ -> "!#{6 |> :crypto.strong_rand_bytes() |> Base.url_encode64()}:localhost" end)

      [to_include | to_exclude] = Enum.take_random(room_ids, 3)
      to_include = [List.first(to_exclude) | [to_include]]

      filter = %{"room" => %{"not_rooms" => to_exclude, "rooms" => to_include}}
      filtered_rooms = Filter.apply_rooms(filter, room_ids)

      assert Enum.all?(to_exclude, &(&1 not in filtered_rooms))
      assert Enum.all?(to_include, &if(&1 in to_exclude, do: &1 not in filtered_rooms, else: &1 in filtered_rooms))
    end
  end

  defp event(room_id, type, sender_id, content, state_key \\ nil) do
    %{
      "event_id" => "$#{12 |> :crypto.strong_rand_bytes() |> Base.url_encode64()}:localhost",
      "content" => content,
      "room_id" => room_id,
      "sender" => sender_id,
      "type" => type
    }
    |> then(&if is_nil(state_key), do: &1, else: Map.put(&1, "state_key", state_key))
  end
end
