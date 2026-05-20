defmodule RadioBeamWeb.Plugs.OAuth2.VerifyAccessTokenCookieTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Phoenix.ConnTest, only: [fetch_flash: 1]

  alias RadioBeam.User.Authentication.OAuth2
  alias RadioBeamWeb.Plugs.OAuth2.VerifyAccessTokenCookie

  describe "call/2" do
    setup do
      account = Fixtures.create_account()
      device = Fixtures.create_device(account.user_id)

      %{account: account, device: device}
    end

    test "returns the conn with a :user_id and :device_id assign when given a valid access token", %{
      device: %{id: device_id} = device,
      account: %{user_id: user_id}
    } do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint")
        |> init_test_session(%{"access_token" => access_token})
        |> VerifyAccessTokenCookie.call([])

      assert ^user_id = conn.assigns.user_id
      assert ^device_id = conn.assigns.device_id
    end

    test "redirects (302) to the login page error when a token isn't given" do
      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint", %{})
        |> init_test_session(%{})
        |> VerifyAccessTokenCookie.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
    end

    test "redirects (302) to the login page when the provided token isn't known" do
      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint")
        |> init_test_session(%{"access_token" => "55burgers55fries"})
        |> VerifyAccessTokenCookie.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
    end

    test "redirects (302) to the login page when an otherwise valid token has expired", %{device: device} do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device, %{}, ttl: {1, :second})

      Process.sleep(2001)

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint")
        |> init_test_session(%{"access_token" => access_token})
        |> VerifyAccessTokenCookie.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
    end

    test "redirects (302) to the login page with a flash error when a user's account has been locked", %{
      account: account,
      device: device
    } do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      {:ok, _} = RadioBeam.Admin.lock_account(account.user_id, hd(RadioBeam.Config.admins()))

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint")
        |> init_test_session(%{"access_token" => access_token})
        |> fetch_flash()
        |> VerifyAccessTokenCookie.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "account has been locked"
    end

    test "redirects (302) to the login page when a user's account has been suspended", %{
      account: account,
      device: device
    } do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      {:ok, _} = RadioBeam.Admin.suspend_account(account.user_id, hd(RadioBeam.Config.admins()))

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint")
        |> init_test_session(%{"access_token" => access_token})
        |> fetch_flash()
        |> VerifyAccessTokenCookie.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "account has been suspended"
    end
  end
end
