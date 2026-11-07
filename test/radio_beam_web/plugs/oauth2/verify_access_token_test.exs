defmodule RadioBeamWeb.Plugs.OAuth2.VerifyAccessTokenTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import Plug.Conn
  import Plug.Test

  alias RadioBeam.User.Authentication.OAuth2
  alias RadioBeamWeb.Plugs.OAuth2.VerifyAccessToken

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
        init_conn()
        |> put_req_header("authorization", "Bearer 55burgers55fries")
        |> VerifyAccessToken.call([])

      assert {401, _headers, body} = sent_resp(conn)
      assert body =~ "M_UNKNOWN_TOKEN"
    end

    test "returns an unknown token (401) error when the device associated with the token has been deleted", %{
      account: %{user_id: user_id},
      device: device
    } do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      :ok = RadioBeam.User.delete_device(user_id, device.id)

      conn =
        init_conn()
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> VerifyAccessToken.call([])

      assert {401, _headers, body} = sent_resp(conn)
      assert body =~ "M_UNKNOWN_TOKEN"
    end

    test "returns an unknown token (401) error when the request comes in via the wrong host", %{device: device} do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      logs =
        capture_log(fn ->
          conn =
            init_conn()
            |> Map.put(:host, "some.other.site")
            |> put_req_header("authorization", "Bearer #{access_token}")
            |> VerifyAccessToken.call([])

          assert {401, _headers, body} = sent_resp(conn)
          assert body =~ "M_UNKNOWN_TOKEN"
        end)

      assert logs =~ "user client request used wrong host"
    end

    test "returns an fatal error message (500) when the token is valid but the user's homeserver is not configured" do
      account = Fixtures.create_account("@hihello:wait.whats-this.server")
      device = Fixtures.create_device(account.user_id)

      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      logs =
        capture_log(fn ->
          conn =
            init_conn()
            |> put_req_header("authorization", "Bearer #{access_token}")
            |> VerifyAccessToken.call([])

          assert {500, _headers, body} = sent_resp(conn)
          assert body =~ "M_NOT_FOUND"
          assert body =~ "Homeserver has moved. Contact your server administrator"
        end)

      assert logs =~ "is (no longer) configured in RadioBeam"
    end

    test "returns an unknown token (401) error when an otherwise valid token has expired", %{device: device} do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device, %{}, ttl: {1, :second})

      Process.sleep(2001)

      conn =
        init_conn()
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> VerifyAccessToken.call([])

      assert {401, _headers, body} = sent_resp(conn)
      %{"errcode" => "M_UNKNOWN_TOKEN", "soft_logout" => true} = JSON.decode!(body)
    end

    test "returns M_USER_LOCKED (401) when a user's account has been locked", %{account: account, device: device} do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      {:ok, _} = RadioBeam.Admin.lock_account(account.user_id, hd(RadioBeam.Config.admins("localhost")))

      conn =
        init_conn()
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> VerifyAccessToken.call([])

      assert {401, _headers, body} = sent_resp(conn)
      %{"errcode" => "M_USER_LOCKED", "error" => error, "soft_logout" => true} = JSON.decode!(body)
      assert error =~ "account has been locked"
    end

    test "returns M_USER_SUSPENDED (403) when a user's account has been suspended", %{account: account, device: device} do
      {:ok, access_token, _claims} = OAuth2.Builtin.Guardian.encode_and_sign(device)

      {:ok, _} = RadioBeam.Admin.suspend_account(account.user_id, hd(RadioBeam.Config.admins("localhost")))

      conn =
        init_conn()
        |> put_req_header("authorization", "Bearer #{access_token}")
        |> VerifyAccessToken.call([])

      assert {403, _headers, body} = sent_resp(conn)
      %{"errcode" => "M_USER_SUSPENDED", "error" => error} = JSON.decode!(body)
      assert error =~ "account has been suspended"
    end
  end

  defp init_conn do
    conn = conn(:post, "/_matrix/v3/some_endpoint")
    put_in(conn.host, @server_name)
  end
end
