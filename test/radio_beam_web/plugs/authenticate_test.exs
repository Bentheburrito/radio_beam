defmodule RadioBeamWeb.Plugs.AuthenticateTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias RadioBeam.Device
  alias RadioBeamWeb.Plugs.Authenticate

  describe "call/2" do
    setup do
      user = Fixtures.user("@timotheec:matrix.org")
      device = Fixtures.device(user.id)

      %{user: user, device: device}
    end

    test "returns the conn with a :user assign when given a valid access token", %{device: device, user: user} do
      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint?access_token=#{device.access_token}")
        |> Authenticate.call([])

      assert %{user: ^user} = conn.assigns
    end

    test "returns a missing token (400) error when a token isn't given" do
      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint", %{})
        |> Authenticate.call([])

      assert {400, _headers, body} = sent_resp(conn)
      assert body =~ "M_MISSING_TOKEN"
    end

    test "returns an unknown token (400) error when the provided token isn't known" do
      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint?access_token=55burgers55fries")
        |> Authenticate.call([])

      assert {400, _headers, body} = sent_resp(conn)
      assert body =~ "M_UNKNOWN_TOKEN"
    end

    test "returns an unknown token (400) error when an otherwise valid token has expired", %{device: device} do
      device = %Device{device | expires_at: DateTime.utc_now()}
      Fixtures.write!(device)

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint?access_token=#{device.access_token}")
        |> Authenticate.call([])

      assert {400, _headers, body} = sent_resp(conn)
      assert body =~ "M_UNKNOWN_TOKEN"
    end
  end
end
