defmodule RadioBeam.Sync.Source.ToDeviceMessageTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Sync.Source.ToDeviceMessage
  alias RadioBeam.User

  setup do
    account = Fixtures.create_account()
    device = Fixtures.create_device(account.user_id)

    %{inputs: %{user_id: account.user_id, device_id: device.id, last_batch: nil}}
  end

  describe "run/3" do
    test "will immediately notify_waiting", %{inputs: inputs} do
      me = self()

      Task.start(fn -> ToDeviceMessage.run(inputs, inspect(ToDeviceMessage), me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
    end

    test "returns when user joins a new room, after notifying waiting", %{inputs: inputs} do
      me = self()

      task = Task.async(fn -> ToDeviceMessage.run(inputs, inspect(ToDeviceMessage), me) end)

      assert_receive {:sync_waiting, _}, :timer.seconds(1)
      assert is_nil(Task.yield(task, 0))

      User.send_to_devices(
        %{inputs.user_id => %{inputs.device_id => %{"hello2" => "world"}}},
        "@hello:world",
        "com.spectrum.corncobtv.notification"
      )

      assert {:ok, [%{type: "com.spectrum.corncobtv.notification"}], 0} = Task.await(task)

      User.send_to_devices(
        %{inputs.user_id => %{inputs.device_id => %{"hello2" => "world"}}},
        "@hello:world",
        "org.some.other.event"
      )

      assert {:ok, [%{type: "org.some.other.event"}], 1} =
               inputs |> Map.put(:last_batch, "0") |> ToDeviceMessage.run(inspect(ToDeviceMessage), me)
    end
  end
end
