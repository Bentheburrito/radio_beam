defmodule RadioBeamWeb.Plugs.AuthenticateTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias RadioBeam.Repo
  alias RadioBeam.User
  alias RadioBeam.User.Auth
  alias RadioBeam.User.Device
  alias RadioBeamWeb.Plugs.Authenticate

  describe "call/2" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())

      %{user: user, device: device}
    end

    test "returns the conn with a :user assign when given a valid access token", %{device: device, user: user} do
      %{access_token: access_token} = Auth.session_info(user, device)

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint?access_token=#{access_token}")
        |> Authenticate.call([])

      assert %{user: ^user} = conn.assigns
    end

    test "returns a missing token (401) error when a token isn't given" do
      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint", %{})
        |> Authenticate.call([])

      assert {401, _headers, body} = sent_resp(conn)
      assert body =~ "M_MISSING_TOKEN"
    end

    test "returns an unknown token (401) error when the provided token isn't known" do
      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint?access_token=55burgers55fries")
        |> Authenticate.call([])

      assert {401, _headers, body} = sent_resp(conn)
      assert body =~ "M_UNKNOWN_TOKEN"
    end

    test "returns an unknown token (401) error when an otherwise valid token has expired", %{user: user, device: device} do
      user = User.put_device(user, Device.expire(device))
      Repo.insert(user)
      {:ok, device} = User.get_device(user, device.id)
      %{access_token: access_token} = Auth.session_info(user, device)

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint?access_token=#{access_token}")
        |> Authenticate.call([])

      assert {401, _headers, body} = sent_resp(conn)
      %{"errcode" => "M_UNKNOWN_TOKEN", "soft_logout" => true} = JSON.decode!(body)
    end
  end
end
