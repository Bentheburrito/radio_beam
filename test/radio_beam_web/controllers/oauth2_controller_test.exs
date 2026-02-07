defmodule RadioBeamWeb.OAuth2ControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.User.Authentication.OAuth2

  describe "get_auth_metadata/2" do
    test "returns auth metadata (200)", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v1/auth_metadata", %{})

      assert %{
               "code_challenge_methods_supported" => ["S256"],
               "grant_types_supported" => ["authorization_code", "refresh_token"],
               "prompt_values_supported" => ["create"],
               "response_modes_supported" => ["query", "fragment"],
               "response_types_supported" => ["code"]
             } =
               json_response(conn, 200)
    end
  end

  describe "register_client/2" do
    test "returns the registered client attrs when they are valid (200)", %{conn: conn} do
      conn =
        post(conn, ~p"/oauth2/clients/register", %{
          application_type: "web",
          client_uri: "https://my.little.matrix.client.com",
          grant_types: ["authorization_code", "refresh_token"],
          redirect_uris: ["https://my.little.matrix.client.com/callback"],
          response_types: ["code"],
          token_endpoint_auth_method: "none",
          extra_ignored_key: "whatever"
        })

      %{
        "application_type" => "web",
        "client_uri" => "https://my.little.matrix.client.com",
        "grant_types" => ["authorization_code", "refresh_token"],
        "redirect_uris" => ["https://my.little.matrix.client.com/callback"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      } = res = json_response(conn, 200)

      refute is_map_key(res, "extra_ignored_key")
    end

    test "returns an error when the attrs are invalid (400)", %{conn: conn} do
      conn =
        post(conn, ~p"/oauth2/clients/register", %{
          application_type: "typewriter",
          client_uri: "https://my.little.matrix.client.com",
          grant_types: ["authorization_code", "refresh_token"],
          redirect_uris: ["https://my.little.matrix.client.com/callback"],
          response_types: ["code"],
          token_endpoint_auth_method: "none",
          extra_ignored_key: "whatever"
        })

      %{
        "error" => "invalid_client_metadata",
        "error_description" => "Invalid client metadata: unsupported_application_type 'typewriter'"
      } = json_response(conn, 400)
    end
  end

  describe "authenticate/2" do
    test "puts the expected assigns and session data to prepare to accept the login/create account form", %{conn: conn} do
      {:ok, %{client_id: client_id}} =
        OAuth2.register_client(%{
          "application_type" => "web",
          "client_uri" => "https://my.little.matrix.client.com",
          "grant_types" => ["authorization_code", "refresh_token"],
          "redirect_uris" => ["https://my.little.matrix.client.com/callback"],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none",
          "extra_ignored_key" => "whatever"
        })

      code_verifier = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
      device_id = Fixtures.device_id()

      attrs = %{
        client_id: client_id,
        scope: "urn:matrix:client:device:#{device_id} urn:matrix:client:api:*",
        redirect_uri: "https://my.little.matrix.client.com/callback",
        state: "abcdefg123123",
        response_type: "code",
        code_challenge_method: "S256",
        code_challenge: code_challenge
      }

      for attrs <- [attrs, Map.put(attrs, :prompt, "create")] do
        conn = get(conn, ~p"/oauth2/auth", attrs)

        expected_session_prompt = if is_nil(attrs[:prompt]), do: :login, else: :create

        assert %{
                 "client_id" => ^client_id,
                 "code_challenge" => ^code_challenge,
                 "code_challenge_method" => "S256",
                 "prompt" => ^expected_session_prompt,
                 "redirect_uri" => "https://my.little.matrix.client.com/callback",
                 "response_mode" => "query",
                 "response_type" => "code",
                 "scope" => %{cs_api: [:read, :write], device_id: ^device_id},
                 "state" => "abcdefg123123"
               } = get_session(conn)

        assert %{
                 scope: %{cs_api: [:read, :write], device_id: ^device_id},
                 form: %Phoenix.HTML.Form{},
                 prompt: ^expected_session_prompt,
                 server_name: "localhost",
                 layout: false,
                 flash: %{},
                 submit_to: "http://www.example.com:80/oauth2/auth",
                 oauth_params_to_swap_flow:
                   %{
                     state: "abcdefg123123",
                     client_id: ^client_id,
                     code_challenge: ^code_challenge,
                     redirect_uri: "https://my.little.matrix.client.com/callback",
                     response_type: "code"
                   } = swap_params,
                 client_name: "A Matrix Client (name not provided)"
               } =
                 conn.assigns

        assert html = html_response(conn, 200)
        assert html =~ "User ID Localpart"
        assert html =~ "Password"

        if is_nil(attrs[:prompt]) do
          assert html =~ "Login to your account"
          assert :create == swap_params.prompt
        else
          assert html =~ "Register your account"
        end
      end
    end

    test "responds with an error page when the client is unregistered or required info is missing", %{conn: conn} do
      conn = get(conn, ~p"/oauth2/auth", %{client_id: "blahblahblah"})

      assert html = html_response(conn, 200)
      assert html =~ "The Matrix client you are using seems to be missing some required information"
      assert html =~ "Missing Client Registration"
    end

    test "responds with an error page when the redirect URI was not among those registered", %{conn: conn} do
      {:ok, %{client_id: client_id}} =
        OAuth2.register_client(%{
          "application_type" => "web",
          "client_uri" => "https://my.little.matrix.client.com",
          "grant_types" => ["authorization_code", "refresh_token"],
          "redirect_uris" => ["https://my.little.matrix.client.com/callback"],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none",
          "extra_ignored_key" => "whatever"
        })

      code_verifier = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
      device_id = Fixtures.device_id()

      conn =
        get(conn, ~p"/oauth2/auth", %{
          client_id: client_id,
          scope: "urn:matrix:client:device:#{device_id} urn:matrix:client:api:*",
          redirect_uri: "https://my.awesome.matrix.client.com/callback",
          state: "abcdefg123123",
          response_type: "code",
          code_challenge_method: "S256",
          code_challenge: code_challenge
        })

      assert html = html_response(conn, 200)
      assert html =~ "The Matrix client you are using seems to be missing some required information"
      assert html =~ "Unknown redirection URI"
    end

    test "redirects with an error to the redirect URI when a state value is missing", %{conn: conn} do
      {:ok, %{client_id: client_id}} =
        OAuth2.register_client(%{
          "application_type" => "web",
          "client_uri" => "https://my.little.matrix.client.com",
          "grant_types" => ["authorization_code", "refresh_token"],
          "redirect_uris" => ["https://my.little.matrix.client.com/callback"],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none",
          "extra_ignored_key" => "whatever"
        })

      code_verifier = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
      device_id = Fixtures.device_id()

      conn =
        get(conn, ~p"/oauth2/auth", %{
          client_id: client_id,
          scope: "urn:matrix:client:device:#{device_id} urn:matrix:client:api:*",
          redirect_uri: "https://my.little.matrix.client.com/callback",
          response_type: "code",
          code_challenge_method: "S256",
          code_challenge: code_challenge
        })

      assert redir_error_uri = redirected_to(conn)
      assert redir_error_uri =~ "https://my.little.matrix.client.com/callback"
      assert redir_error_uri =~ "error=invalid_request"
      assert redir_error_uri =~ "error_description=This+homeserver+requires+a+client-provided+%60state%60+value"
    end

    test "redirects with an error to the redirect URI when response_type is invalid", %{conn: conn} do
      {:ok, %{client_id: client_id}} =
        OAuth2.register_client(%{
          "application_type" => "web",
          "client_uri" => "https://my.little.matrix.client.com",
          "grant_types" => ["authorization_code", "refresh_token"],
          "redirect_uris" => ["https://my.little.matrix.client.com/callback"],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "none",
          "extra_ignored_key" => "whatever"
        })

      code_verifier = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
      device_id = Fixtures.device_id()

      conn =
        get(conn, ~p"/oauth2/auth", %{
          client_id: client_id,
          scope: "urn:matrix:client:device:#{device_id} urn:matrix:client:api:*",
          redirect_uri: "https://my.little.matrix.client.com/callback",
          response_type: "something_else",
          state: "abcdefg123123",
          code_challenge_method: "S256",
          code_challenge: code_challenge
        })

      assert redir_error_uri = redirected_to(conn)
      assert redir_error_uri =~ "https://my.little.matrix.client.com/callback"
      assert redir_error_uri =~ "error=invalid_request"
      assert redir_error_uri =~ "error_description=%3Aresponse_type"
    end
  end

  describe "whoami/2" do
    test "successfully gets a known users's info", %{
      conn: conn,
      device_id: device_id,
      account: %{user_id: user_id}
    } do
      conn = get(conn, ~p"/_matrix/client/v3/account/whoami", %{})

      assert %{"device_id" => ^device_id, "user_id" => ^user_id} = json_response(conn, 200)
    end

    test "returns 401 for an unknown access token", %{conn: conn} do
      assert %{"errcode" => "M_UNKNOWN_TOKEN"} =
               conn
               |> put_req_header("authorization", "Bearer blahblahblah")
               |> get(~p"/_matrix/client/v3/account/whoami", %{})
               |> json_response(401)
    end
  end
end
