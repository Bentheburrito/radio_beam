defmodule RadioBeam.Device.MessageTest do
  use ExUnit.Case, async: true
  doctest RadioBeam.Device.Message

  alias RadioBeam.Device
  alias RadioBeam.Device.Message

  setup do
    user = Fixtures.user()
    %{user: user, device: Fixtures.device(user.id)}
  end

  describe "put_many/3" do
    test "adds an unsent message to a user's devices", %{user: user, device: device1} do
      device2 = Fixtures.device(user.id)

      entries =
        for device_id <- [device1.id, device2.id] do
          {user.id, device_id, Message.new(%{"hello" => "world"}, "@someone:somewhere", "org.msg.type")}
        end

      assert {:ok, 2} = Message.put_many(entries)
      assert {:ok, %Device{messages: %{unsent: [%Message{type: "org.msg.type"}]}}} = Device.get(user.id, device1.id)
    end
  end

  describe "take_unsent/3,4" do
    test "returns :none when there are no unsent messages", %{user: user, device: device} do
      assert :none = Message.take_unsent(user.id, device.id, "abc")
    end

    test "returns unsent messages, marking them as sent with the given since_token", %{user: user, device: device} do
      message1 = Message.new(%{"hola" => "mundo"}, "@yo:hello", "org.msg.type")
      Message.put(user.id, device.id, message1)
      message2 = Message.new(%{"hola" => "mundo"}, "@yo:hello", "com.msg.type")
      Message.put(user.id, device.id, message2)

      assert {:ok, [^message1, ^message2]} = Message.take_unsent(user.id, device.id, "abc")
      assert {:ok, %Device{messages: %{"abc" => [^message2, ^message1]}}} = Device.get(user.id, device.id)
    end

    test "marks messages as read (deletes them)", %{user: user, device: device} do
      message1 = Message.new(%{"hola" => "mundo"}, "@yo:hello", "org.msg.type")
      Message.put(user.id, device.id, message1)
      message2 = Message.new(%{"hola" => "mundo"}, "@yo:hello", "com.msg.type")
      Message.put(user.id, device.id, message2)

      Message.take_unsent(user.id, device.id, "abc")

      message3 = Message.new(%{"hola" => "mundo"}, "@yo:hello", "com2.msg.type")
      Message.put(user.id, device.id, message3)

      assert {:ok, [^message3]} = Message.take_unsent(user.id, device.id, "xyz", "abc")
      assert {:ok, %Device{messages: messages}} = Device.get(user.id, device.id)
      refute is_map_key(messages, "abc")
      assert %{"xyz" => [^message3]} = messages
    end
  end

  describe "expand_device_id/2" do
    test "expands glob (*) to all a user's device IDs", %{user: user, device: %{id: d1}} do
      %{id: d2} = Fixtures.device(user.id)
      %{id: d3} = Fixtures.device(user.id)

      expected_ids = Enum.sort([d1, d2, d3])
      assert ^expected_ids = Enum.sort(Message.expand_device_id(user.id, "*"))
    end

    test "wraps a device ID in a list", %{user: user, device: %{id: d1}} do
      assert [^d1] = Message.expand_device_id(user.id, d1)
    end
  end
end
