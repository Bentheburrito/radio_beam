defmodule RadioBeamWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use RadioBeamWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint RadioBeamWeb.Endpoint

      use RadioBeamWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import RadioBeamWeb.ConnCase
    end
  end

  setup tags do
    # RadioBeam.DataCase.setup_sandbox(tags)

    {:ok, setup_authenticated_user(Phoenix.ConnTest.build_conn(), tags)}
  end

  defp setup_authenticated_user(conn, tags) do
    user = Fixtures.user()

    code_verifier = 24 |> :crypto.strong_rand_bytes() |> Base.encode64()
    code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
    client_id = "test_client"
    redirect_uri = URI.new!("")
    device_id = Fixtures.device_id()
    scope = %{:cs_api => [:read, :write], device_id: device_id}

    grant_params = %{
      code_challenge: code_challenge,
      client_id: client_id,
      redirect_uri: redirect_uri,
      scope: scope,
      prompt: :login
    }

    device_opts =
      case tags do
        %{device_display_name: display_name} -> [display_name: display_name]
        %{} -> []
      end

    {:ok, code} =
      RadioBeam.User.Authentication.OAuth2.authenticate_user_by_password(
        user.id,
        Fixtures.strong_password(),
        grant_params
      )

    {:ok, access_token, refresh_token, _claims, _expires_in} =
      RadioBeam.User.Authentication.OAuth2.exchange_authz_code_for_tokens(
        code,
        code_verifier,
        client_id,
        redirect_uri,
        device_opts
      )

    {:ok, %{user: user, device: device}} =
      RadioBeam.User.Authentication.OAuth2.authenticate_user_by_access_token(access_token, {127, 0, 0, 1})

    %{
      conn: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{access_token}"),
      user: user,
      device: device,
      access_token: access_token,
      refresh_token: refresh_token
    }
  end
end
