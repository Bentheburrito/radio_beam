defmodule RadioBeamTest do
  use ExUnit.Case, async: true

  describe "client_event/1" do
    test "strips a regular event of non-Client-Server event keys" do
      event = %{"event_id" => "$abc", "depth" => 123}
      client_event = RadioBeam.client_event(event)
      assert 1 = map_size(client_event)
      assert %{"event_id" => "$abc"} = client_event
    end

    test "strips the `state_key` key of an event if it's `nil`" do
      event = %{"state_key" => "xyz", "event_id" => "$abc", "depth" => 123}
      client_event = RadioBeam.client_event(event)
      assert 2 = map_size(client_event)
      assert %{"state_key" => "xyz", "event_id" => "$abc"} = client_event

      event = %{"state_key" => nil, "event_id" => "$abc", "depth" => 123}
      client_event = RadioBeam.client_event(event)
      assert 1 = map_size(client_event)
      assert %{"event_id" => "$abc"} = client_event
    end
  end
end
