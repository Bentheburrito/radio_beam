defmodule RadioBeam.DeviceTest do
  use ExUnit.Case

  alias RadioBeam.Device

  @user_id "@hello:world"
  @password "Ar3allyg00dpwd!@#$"
  setup_all do
    {:ok, user} = RadioBeam.User.new(@user_id, @password)
    {:ok, user} = RadioBeam.Repo.insert(user)
    %{user: user}
  end

  describe "new/1" do
    test "can create a new device from params with a valid user ID and status" do
      params = %{
        "id" => Device.generate_token(),
        "user_id" => @user_id,
        "display_name" => "Eye phone",
        "access_token" => Device.generate_token(),
        "refresh_token" => Device.generate_token()
      }

      assert {:ok, %Device{user_id: @user_id}} = Device.new(params)
    end

    test "will not create a device with an invalid user ID" do
      params = %{
        "id" => Device.generate_token(),
        "user_id" => "@does_not:exist.com",
        "display_name" => "Eye phone",
        "access_token" => Device.generate_token(),
        "refresh_token" => Device.generate_token()
      }

      assert {:error, _} = Device.new(params)
    end
  end
end
