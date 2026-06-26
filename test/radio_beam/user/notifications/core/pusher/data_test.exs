defmodule RadioBeam.User.Notifications.Core.Pusher.DataTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.Notifications.Core.Pusher.Data

  describe "new/2" do
    test "creates a valid http PusherData" do
      assert {:ok, %Data{} = pusher_data} =
               Data.new("http", %{"url" => "https://some.gateway.com/_matrix/push/v1/notify"})

      assert %{url: %URI{host: "some.gateway.com"}} = Data.required_fields(pusher_data)
      assert :http = Data.kind(pusher_data)
    end

    test "creates a valid email PusherData" do
      assert {:ok, %Data{} = pusher_data} = Data.new("email", %{"some_data" => "extra"})
      assert %{} = required_fields = Data.required_fields(pusher_data)
      assert 0 = map_size(required_fields)
      assert :email = Data.kind(pusher_data)
    end

    test "returns an error for unsupported pusher types" do
      assert {:error, :unsupported_kind} = Data.new("idk", %{})
    end

    test "returns an error for malformed urls given 'http' kind" do
      invalid_data = [
        Data.new("http", %{}),
        Data.new("http", %{"url" => "invalidurl"}),
        Data.new("http", %{"url" => "http://some.gateway.com/_matrix/push/v1/notify"}),
        Data.new("http", %{"url" => "https://some.gateway.com/_matrix/push/"}),
        Data.new("http", %{"url" => "https:///_matrix/push/v1/notify"})
      ]

      for data <- invalid_data do
        assert {:error, error} = data
        assert error in ~w|url missing_url|a
      end
    end
  end
end
