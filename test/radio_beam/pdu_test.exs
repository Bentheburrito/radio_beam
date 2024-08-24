defmodule RadioBeam.PDUTest do
  use ExUnit.Case, async: true

  alias RadioBeam.PDU

  describe "new/2" do
    @content %{"msgtype" => "m.text", "body" => "Hello world"}

    @attrs %{
      "auth_events" => ["$somethingsomething"],
      "content" => @content,
      "depth" => 12,
      "prev_events" => ["$somethingelse"],
      "prev_state" => %{},
      "room_id" => "!room:localhost",
      "sender" => "@someone:localhost",
      "type" => "m.room.message"
    }
    test "successfully creates a Room V11 PDU" do
      assert {:ok, %PDU{content: @content}} = PDU.new(@attrs, "11")
    end

    test "errors when a required key is missing" do
      {:error, {:required_param, "type"}} = PDU.new(Map.delete(@attrs, "type"), "11")
    end
  end
end
