defmodule RadioBeamWeb.Plugs.OAuth2.VerifyAccessTokenTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias RadioBeam.User.Authentication.OAuth2
  alias RadioBeamWeb.Plugs.OAuth2.VerifyAccessToken

  describe "call/2" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())

      %{user: user, device: device}
    end

    test "returns the conn with a :user_id and :device_id assign when given a valid access token", %{
      device: %{id: device_id} = device,
      user: %{id: user_id}
    } do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint")
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> VerifyAccessToken.call([])

      assert ^user_id = conn.assigns.user_id
      assert ^device_id = conn.assigns.device_id
    end

    test "returns a missing token (401) error when a token isn't given" do
      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint", %{})
        |> VerifyAccessToken.call([])

      assert {401, _headers, body} = sent_resp(conn)
      assert body =~ "M_MISSING_TOKEN"
    end

    test "returns an unknown token (401) error when the provided token isn't known" do
      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint")
        |> put_req_header("authorization", "Bearer 55burgers55fries")
        |> VerifyAccessToken.call([])

      assert {401, _headers, body} = sent_resp(conn)
      assert body =~ "M_UNKNOWN_TOKEN"
    end

    test "returns an unknown token (401) error when an otherwise valid token has expired", %{device: device} do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device, %{}, ttl: {1, :second})

      Process.sleep(2001)

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint")
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> VerifyAccessToken.call([])

      assert {401, _headers, body} = sent_resp(conn)
      %{"errcode" => "M_UNKNOWN_TOKEN", "soft_logout" => true} = JSON.decode!(body)
    end
  end
end
