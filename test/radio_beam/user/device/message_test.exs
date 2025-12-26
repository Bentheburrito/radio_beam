defmodule RadioBeam.User.Device.MessageTest do
  use ExUnit.Case, async: true
  doctest RadioBeam.User.Device.Message

  alias RadioBeam.User
  alias RadioBeam.User.Database
  alias RadioBeam.User.Device
  alias RadioBeam.User.Device.Message

  setup do
    {user, device} = Fixtures.device(Fixtures.user())
    %{user: user, device: device}
  end

  describe "put_many/3" do
    test "adds an unsent message to a user's devices", %{user: user, device: device1} do
      {user, device2} = Fixtures.device(user)

      message = %{"hello" => "world"}
      entries = %{user.id => %{device1.id => message, device2.id => message}}

      assert :ok = Message.put_many(entries, "@someone:somewhere", "org.msg.type")
      {:ok, user} = Database.fetch_user(user.id)
      assert {:ok, %Device{messages: %{unsent: [%Message{type: "org.msg.type"}]}}} = User.get_device(user, device1.id)
    end
  end

  describe "take_unsent/3,4" do
    test "returns :none when there are no unsent messages", %{user: user, device: device} do
      assert :none = Message.take_unsent(user.id, device.id, "abc")
    end

    test "returns unsent messages, marking them as sent with the given since_token", %{user: user, device: device} do
      message1 = %{"hola" => "mundo"}
      Message.put(user.id, device.id, message1, "@yo:hello", "org.msg.type")
      message2 = %{"hola" => "mundo"}
      Message.put(user.id, device.id, message2, "@yo:hello", "com.msg.type")
      {:ok, user} = Database.fetch_user(user.id)

      assert {:ok, [%Message{content: ^message1}, %Message{content: ^message2}]} =
               Message.take_unsent(user.id, device.id, "abc")

      {:ok, user} = Database.fetch_user(user.id)

      assert {:ok, %Device{messages: %{"abc" => [%Message{content: ^message2}, %Message{content: ^message1}]}}} =
               User.get_device(user, device.id)
    end

    test "marks messages as read (deletes them)", %{user: user, device: device} do
      message1 = %{"hola" => "mundo"}
      Message.put(user.id, device.id, message1, "@yo:hello", "org.msg.type")
      message2 = %{"hola" => "mundo"}
      Message.put(user.id, device.id, message2, "@yo:hello", "com.msg.type")

      Message.take_unsent(user.id, device.id, "abc")

      message3 = %{"hola" => "mundo"}
      Message.put(user.id, device.id, message3, "@yo:hello", "com2.msg.type")

      assert {:ok, [%Message{content: ^message3}]} = Message.take_unsent(user.id, device.id, "xyz", "abc")
      {:ok, user} = Database.fetch_user(user.id)
      assert {:ok, %Device{messages: messages}} = User.get_device(user, device.id)
      refute is_map_key(messages, "abc")
      assert %{"xyz" => [%Message{content: ^message3}]} = messages
    end
  end
end
