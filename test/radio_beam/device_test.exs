defmodule RadioBeam.DeviceTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Device

  describe "get/2" do
    setup do
      user = Fixtures.user()
      %{user: user, device: Fixtures.device(user.id)}
    end

    test "returns a user's device", %{user: user, device: device} do
      user_id = user.id
      assert {:ok, %Device{user_id: ^user_id}} = Device.get(user.id, device.id)
    end

    test "returns an error if not device is found for a valid user", %{user: user} do
      assert {:error, :not_found} = Device.get(user.id, "does not exist")
    end
  end

  describe "get_all_by_user/2" do
    setup do
      user = Fixtures.user()
      Fixtures.device(user.id)
      Fixtures.device(user.id)

      %{user: user, user_no_devices: Fixtures.user()}
    end

    test "gets all of a user's devices", %{user: user, user_no_devices: user2} do
      assert {:ok, devices} = Device.get_all_by_user(user.id)
      assert 2 = length(devices)
      assert {:ok, []} = Device.get_all_by_user(user2.id)
    end
  end
end
