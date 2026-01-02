defmodule RadioBeam.User.Device.MessageTest do
  use ExUnit.Case, async: true
  doctest RadioBeam.User.Device.Message

  alias RadioBeam.User.Device
  alias RadioBeam.User.Device.Message

  setup do
    account = Fixtures.create_account()
    device = Fixtures.create_device(account.user_id)
    %{device: device}
  end

  describe "put/4" do
    test "adds an unsent message to a user's devices", %{device: device1} do
      message = %{"hello" => "world"}

      device1 = Message.put(device1, message, "@someone:somewhere", "org.msg.type")

      assert %Device{messages: %{unsent: [%Message{type: "org.msg.type"}]}} = device1
    end
  end

  describe "pop_unsent/2,3" do
    test "returns :none when there are no unsent messages", %{device: device} do
      assert {:none, ^device} = Message.pop_unsent(device, "abc")
    end

    test "returns unsent messages, marking them as sent with the given since_token", %{device: device} do
      message1 = %{"hola" => "mundo"}
      device = Message.put(device, message1, "@yo:hello", "org.msg.type")
      message2 = %{"hola" => "mundo"}
      device = Message.put(device, message2, "@yo:hello", "com.msg.type")

      assert {[%Message{content: ^message1}, %Message{content: ^message2}], device} = Message.pop_unsent(device, "abc")

      assert %Device{messages: %{"abc" => [%Message{content: ^message2}, %Message{content: ^message1}]}} =
               device
    end

    test "marks messages as read (deletes them)", %{device: device} do
      message1 = %{"hola" => "mundo"}
      device = Message.put(device, message1, "@yo:hello", "org.msg.type")
      message2 = %{"hola" => "mundo"}
      device = Message.put(device, message2, "@yo:hello", "com.msg.type")

      {_messages, device} = Message.pop_unsent(device, "abc")

      message3 = %{"hola" => "mundo"}
      device = Message.put(device, message3, "@yo:hello", "com2.msg.type")

      assert {[%Message{content: ^message3}], %Device{messages: messages}} = Message.pop_unsent(device, "xyz", "abc")
      refute is_map_key(messages, "abc")
      assert %{"xyz" => [%Message{content: ^message3}]} = messages
    end
  end
end
