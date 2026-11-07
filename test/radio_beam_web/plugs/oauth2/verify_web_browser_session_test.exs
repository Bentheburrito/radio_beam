defmodule RadioBeamWeb.Plugs.OAuth2.VerifyWebBrowserSessionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import Phoenix.ConnTest, only: [fetch_flash: 1]
  import Plug.Test

  alias RadioBeam.User.Authentication.OAuth2
  alias RadioBeamWeb.Plugs.OAuth2.VerifyWebBrowserSession

  @server_name RadioBeam.local_homeservers() |> hd() |> Map.fetch!(:server_display_name)

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
        init_conn()
        |> init_test_session(%{"access_token" => access_token})
        |> VerifyWebBrowserSession.call([])

      assert ^user_id = conn.assigns.user_id
      assert ^device_id = conn.assigns.device_id
    end

    test "redirects (302) to the login page error when a token isn't given" do
      conn =
        init_conn()
        |> init_test_session(%{})
        |> VerifyWebBrowserSession.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
    end

    test "redirects (302) to the login page when the provided token isn't known" do
      conn =
        init_conn()
        |> init_test_session(%{"access_token" => "55burgers55fries"})
        |> VerifyWebBrowserSession.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
    end

    test "redirects (302) to the login page when an otherwise valid token has expired", %{device: device} do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device, %{}, ttl: {1, :second})

      Process.sleep(2001)

      conn =
        init_conn()
        |> init_test_session(%{"access_token" => access_token})
        |> VerifyWebBrowserSession.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
    end

    test "redirects (302) to the login page with a flash error when a user's account has been locked", %{
      account: account,
      device: device
    } do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      {:ok, _} = RadioBeam.Admin.lock_account(account.user_id, hd(RadioBeam.Config.admins("localhost")))

      conn =
        init_conn()
        |> init_test_session(%{"access_token" => access_token})
        |> fetch_flash()
        |> VerifyWebBrowserSession.call([])

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

      {:ok, _} = RadioBeam.Admin.suspend_account(account.user_id, hd(RadioBeam.Config.admins("localhost")))

      conn =
        init_conn()
        |> init_test_session(%{"access_token" => access_token})
        |> fetch_flash()
        |> VerifyWebBrowserSession.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "account has been suspended"
    end

    test "redirects (302) to the login page when the device associated with the token has been deleted", %{
      account: %{user_id: user_id},
      device: device
    } do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      :ok = RadioBeam.User.delete_device(user_id, device.id)

      conn =
        init_conn()
        |> init_test_session(%{"access_token" => access_token})
        |> VerifyWebBrowserSession.call([])

      assert {302, headers, body} = sent_resp(conn)
      Enum.any?(headers, &(&1 == {"location", "/account/login"}))
      assert body =~ "/account/login"
    end

    test "redirects (302) to the login page when the request comes in via the wrong host", %{device: device} do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      logs =
        capture_log(fn ->
          conn =
            init_conn()
            |> init_test_session(%{"access_token" => access_token})
            |> Map.put(:host, "some.other.site")
            |> VerifyWebBrowserSession.call([])

          assert {302, headers, body} = sent_resp(conn)
          Enum.any?(headers, &(&1 == {"location", "/account/login"}))
          assert body =~ "/account/login"
        end)

      assert logs =~ "user client request used wrong host"
    end

    test "redirects (302) to the login page when the token is valid but the user's homeserver is not configured" do
      account = Fixtures.create_account("@hithere:wait.whats-this.server")
      device = Fixtures.create_device(account.user_id)

      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      logs =
        capture_log(fn ->
          conn =
            init_conn()
            |> init_test_session(%{"access_token" => access_token})
            |> fetch_flash()
            |> VerifyWebBrowserSession.call([])

          assert {302, headers, body} = sent_resp(conn)
          Enum.any?(headers, &(&1 == {"location", "/account/login"}))
          assert body =~ "/account/login"
        end)

      assert logs =~ "is (no longer) configured in RadioBeam"
    end
  end

  defp init_conn do
    conn = conn(:post, "/_matrix/v3/some_endpoint")
    put_in(conn.host, @server_name)
  end
end
