defmodule RadioBeam.User.Notifications.Core.PusherTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.Notifications.Core.Pusher

  describe "new/6,7" do
    test "creates a valid Pusher given valid params" do
      params = [
        {"http", %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify"}, "abcdef123"},
        {"email", %{}, "someone@someplace.com"}
      ]

      for {kind, pusher_data_params, pushkey} <- params do
        app_id = "com.a-company.client.matrix.ios"

        assert {:ok, %Pusher{} = pusher} =
                 Pusher.new(kind, app_id, pushkey, "A Company's Client", pusher_data_params, "My iPhone")

        assert ^kind = pusher.data |> Pusher.Data.kind() |> to_string()
        assert ^app_id = pusher.app_id
        assert ^pushkey = pusher.pushkey
        assert "A Company's Client" = pusher.app_display_name
        assert "My iPhone" = pusher.device_display_name
        assert "en" = pusher.lang
        assert is_nil(pusher.profile_tag)
      end
    end

    test "errors given invalid params" do
      app_id = "com.a-company.client.matrix.ios"
      valid_data_params = %{"url" => "https://notifs-gateway.a-company.com/_matrix/push/v1/notify"}
      long_str = String.duplicate("a", 2 ** 10 + 1)

      params = [
        Pusher.new("http", app_id, "abcdef123", "A Company's Client", %{}, "My iPhone"),
        Pusher.new("http", app_id, "abcdef123", "A Company's Client", %{"url" => "invalidurl"}, "My iPhone"),
        Pusher.new("http", app_id, "abcdef123", long_str, valid_data_params, "My iPhone"),
        Pusher.new("http", app_id, "abcdef123", "A Company's Client", valid_data_params, long_str),
        Pusher.new("http", app_id, "abcdef123", "A Company's Client", valid_data_params, "My iPhone",
          profile_tag: long_str
        ),
        Pusher.new("http", app_id, String.duplicate("b", 513), "A Company's Client", valid_data_params, "My iPhone")
      ]

      for pusher_result <- params do
        assert {:error, error} = pusher_result
        assert error in ~w|pushkey profile_tag url missing_url app_display_name device_display_name|a
      end
    end
  end
end
