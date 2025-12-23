defmodule RadioBeamWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  import Kernel, except: [/: 2]
  import RadioBeam.RateLimit, only: [/: 2]

  alias RadioBeamWeb.Plugs.RateLimit
  alias RadioBeam.User.Authentication.OAuth2.UserDeviceSession

  describe "call/2" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())

      {:ok, session} = UserDeviceSession.existing_from_user(user, device.id)
      %{session: session}
    end

    @high_limit 1000 / :timer.minutes(1)

    test "returns the conn unmodified, until the user endpoint rate limit is hit", %{session: session} do
      user_endpoint_limit = 3

      rate_limit =
        RadioBeam.RateLimit.new!(@high_limit, user_endpoint_limit / :timer.minutes(1), @high_limit, @high_limit)

      Enum.each(1..user_endpoint_limit, fn _i ->
        conn =
          :post
          |> conn("/_matrix/v3/some_endpoint")
          |> assign(:rate_limit, rate_limit)
          |> assign(:session, session)

        assert ^conn = RateLimit.call(conn, [])
      end)

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint")
        |> assign(:rate_limit, rate_limit)
        |> assign(:session, session)
        |> RateLimit.call([])

      assert {429, headers_kwlist, body} = sent_resp(conn)
      assert Enum.any?(headers_kwlist, fn {header, _} -> header == "retry-after" end)
      assert body =~ "M_LIMIT_EXCEEDED"

      conn =
        :post
        |> conn("/_matrix/v3/some_other_endpoint")
        |> assign(:rate_limit, rate_limit)
        |> assign(:session, session)
        |> RateLimit.call([])

      refute conn.halted
    end

    test "returns the conn unmodified, until the user device rate limit is hit", %{session: session} do
      user_endpoint_limit = 5
      user_device_limit = 3

      rate_limit =
        RadioBeam.RateLimit.new!(
          @high_limit,
          user_endpoint_limit / :timer.minutes(1),
          user_device_limit / :timer.minutes(1),
          @high_limit
        )

      Enum.each(1..user_device_limit, fn _i ->
        conn =
          :post
          |> conn("/_matrix/v3/another_endpoint")
          |> assign(:rate_limit, rate_limit)
          |> assign(:session, session)

        assert ^conn = RateLimit.call(conn, [])
      end)

      conn =
        :post
        |> conn("/_matrix/v3/another_endpoint")
        |> assign(:rate_limit, rate_limit)
        |> assign(:session, session)
        |> RateLimit.call([])

      assert {429, headers_kwlist, body} = sent_resp(conn)
      assert Enum.any?(headers_kwlist, fn {header, _} -> header == "retry-after" end)
      assert body =~ "M_LIMIT_EXCEEDED"

      {user, device} = Fixtures.device(session.user)
      {:ok, session} = UserDeviceSession.existing_from_user(user, device.id)

      conn =
        :post
        |> conn("/_matrix/v3/cool_stuff")
        |> assign(:rate_limit, rate_limit)
        |> assign(:session, session)
        |> RateLimit.call([])

      refute conn.halted
    end

    test "returns the conn unmodified, until the global endpoint rate limit is hit" do
      global_endpoint_limit = 5

      rate_limit =
        RadioBeam.RateLimit.new!(
          global_endpoint_limit / :timer.minutes(1),
          @high_limit,
          @high_limit,
          @high_limit
        )

      Enum.each(1..global_endpoint_limit, fn _i ->
        conn =
          :post
          |> conn("/_matrix/v3/cool")
          |> assign(:rate_limit, rate_limit)

        assert ^conn = RateLimit.call(conn, [])
      end)

      conn =
        :post
        |> conn("/_matrix/v3/cool")
        |> assign(:rate_limit, rate_limit)
        |> RateLimit.call([])

      assert {429, headers_kwlist, body} = sent_resp(conn)
      assert Enum.any?(headers_kwlist, fn {header, _} -> header == "retry-after" end)
      assert body =~ "M_LIMIT_EXCEEDED"

      conn =
        :post
        |> conn("/_matrix/v3/really_awesome_stuff")
        |> assign(:rate_limit, rate_limit)
        |> RateLimit.call([])

      refute conn.halted
    end

    test "returns the conn unmodified, until the IP-based rate limit is hit" do
      ip_endpoint_limit = 5
      remote_ip = {10, 10, 10, 2}

      rate_limit =
        RadioBeam.RateLimit.new!(
          @high_limit,
          @high_limit,
          @high_limit,
          ip_endpoint_limit / :timer.minutes(1)
        )

      Enum.each(1..ip_endpoint_limit, fn _i ->
        conn =
          :post
          |> conn("/_matrix/v3/awesome_stuff")
          |> assign(:rate_limit, rate_limit)
          |> Map.put(:remote_ip, remote_ip)

        assert ^conn = RateLimit.call(conn, [])
      end)

      conn =
        :post
        |> conn("/_matrix/v3/awesome_stuff")
        |> assign(:rate_limit, rate_limit)
        |> Map.put(:remote_ip, remote_ip)
        |> RateLimit.call([])

      assert {429, headers_kwlist, body} = sent_resp(conn)
      assert Enum.any?(headers_kwlist, fn {header, _} -> header == "retry-after" end)
      assert body =~ "M_LIMIT_EXCEEDED"

      remote_ip = {10, 10, 10, 3}

      conn =
        :post
        |> conn("/_matrix/v3/awesome_stuff")
        |> assign(:rate_limit, rate_limit)
        |> Map.put(:remote_ip, remote_ip)
        |> RateLimit.call([])

      refute conn.halted
    end
  end
end
