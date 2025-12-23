defmodule RadioBeam.User.Authentication.OAuth2.BuiltinTest do
  use ExUnit.Case, async: true
  alias RadioBeam.User.Authentication.OAuth2.Builtin
  alias RadioBeam.User.Authentication.OAuth2.Builtin.DynamicOAuth2Client

  @valid_native_redirect_uris [
    "http://localhost",
    "http://127.0.0.1",
    "http://[::1]",
    "net.itsmytestclient:",
    "net.itsmytestclient:/",
    "net.itsmytestclient.mobile.yo:",
    "net.itsmytestclient.mobile.yo:/",
    "net.itsmytestclient.mobile.yo:/callback",
    "https://yo.itsmytestclient.net/callback",
    "https://itsmytestclient.net/callback",
    "https://yo.itsmytestclient.net/callback?something=this",
    "https://itsmytestclient.net:6544/callback"
  ]

  @valid_web_metadata %{
    "application_type" => "web",
    "client_name" => "My Test Web Client",
    "client_uri" => "https://itsmytestclient.net",
    "grant_types" => ["authorization_code", "refresh_token"],
    "logo_uri" => "https://yo.itsmytestclient.net/logo",
    "policy_uri" => "https://itsmytestclient.net/tos",
    "redirect_uris" => [
      "https://yo.itsmytestclient.net/callback",
      "https://itsmytestclient.net/callback",
      "https://yo.itsmytestclient.net/callback?something=this",
      "https://itsmytestclient.net:6544/callback"
    ],
    "response_types" => ["code"],
    "token_endpoint_auth_method" => "none",
    "tos_uri" => "https://itsmytestclient.net/tos"
  }

  @valid_native_metadata %{
    "application_type" => "native",
    "client_name" => "My Test Mobile Client",
    "client_uri" => "https://itsmytestclient.net",
    "grant_types" => ["authorization_code", "refresh_token"],
    "logo_uri" => "https://mobile.yo.itsmytestclient.net/logo",
    "policy_uri" => "https://itsmytestclient.net/tos",
    "redirect_uris" => @valid_native_redirect_uris,
    "response_types" => ["code"],
    "token_endpoint_auth_method" => "none",
    "tos_uri" => "https://itsmytestclient.net/tos"
  }

  describe "register_client/1" do
    test "successfully registers a client given valid metadata" do
      assert {:ok, %DynamicOAuth2Client{client_id: client_id}} = Builtin.register_client(@valid_web_metadata)
      assert {:ok, %DynamicOAuth2Client{client_id: ^client_id}} = Builtin.lookup_client(client_id)

      assert {:ok, %DynamicOAuth2Client{client_id: client_id}} = Builtin.register_client(@valid_native_metadata)
      assert {:ok, %DynamicOAuth2Client{client_id: ^client_id}} = Builtin.lookup_client(client_id)
    end

    test "rejects invalid metadata for web clients" do
      assert {:error, {:invalid_redirect_uri, %URI{}}} =
               @valid_web_metadata
               |> Map.put("redirect_uris", @valid_native_redirect_uris)
               |> Builtin.register_client()

      invalid_redirect_uris = [
        :not_a_string,
        _scheme_http = "http://yo.itsmytestclient.net/callback",
        _userinfo = "https://someone@yo.itsmytestclient.net/callback",
        _has_fragment = "https://yo.itsmytestclient.net/callback#hi",
        _doesnt_match_client_uri = "https://yo.itsmy-other-testclient.net/callback",
        _invalid_uri = "incoherent@none:sense/"
      ]

      for invalid_uri <- invalid_redirect_uris do
        assert {:error, error} =
                 @valid_web_metadata
                 |> Map.update!("redirect_uris", &(&1 ++ [invalid_uri]))
                 |> Builtin.register_client()

        assert Enum.any?(
                 [
                   {:must_use_client_uri_as_base, "redirect_uris"},
                   {:invalid_redirect_uri, ":"},
                   :redirect_uri_is_not_a_string,
                   {:invalid_redirect_uri, %URI{}}
                 ],
                 &match?(&1, error)
               )
      end

      invalid_params = [
        {"redirect_uris", :delete},
        {"redirect_uris", "notalist"},
        {"application_type", "unsupported"},
        {"client_uri", "http://itsmytestclient.net"},
        {"client_uri", "https://someone@itsmytestclient.net"},
        {"client_uri", "incoherent@none:sense/"},
        {"client_uri", :delete},
        {"grant_types", []},
        {"grant_types", ["authorization_code unsupported"]},
        {"grant_types", "notalist"},
        {"grant_types", :delete},
        {"logo_uri", "https://blahbalbhalbhasdfasdf.com/logo"},
        {"logo_uri", "http://itsmytestclient.net/logo"},
        {"logo_uri", "incoherent@none:sense/"},
        {"response_types", []},
        {"response_types", ["unsupported"]},
        {"response_types", "notalist"},
        {"response_types", :delete},
        {"token_endpoint_auth_method", "unsupported"},
        {"token_endpoint_auth_method", :delete}
      ]

      for {field_name, value_or_action} <- invalid_params do
        client_metadata =
          case value_or_action do
            :delete -> Map.delete(@valid_web_metadata, field_name)
            value -> Map.put(@valid_web_metadata, field_name, value)
          end

        assert {:error, error} = Builtin.register_client(client_metadata)

        assert Enum.any?(
                 [
                   :redirect_uris_not_a_list,
                   :missing_redirect_uris,
                   {:unsupported_application_type, "unsupported"},
                   {:invalid_client_uri, %URI{}},
                   {:invalid_client_uri, ":"},
                   :missing_client_uri,
                   :grant_types_not_a_list,
                   {:missing_required_grant_type, "refresh_token"},
                   :missing_grant_types,
                   {:must_use_client_uri_as_base, "logo_uri"},
                   {:invalid_extra_uri, %URI{}},
                   {:invalid_extra_uri, ":"},
                   :invalid_response_types,
                   {:missing_required_response_type, "code"},
                   :missing_response_types,
                   :unsupported_token_endpoint_auth_method
                 ],
                 &match?(&1, error)
               )
      end
    end

    test "rejects invalid metadata for native clients" do
      invalid_redirect_uris = [
        :not_a_string,
        _scheme_http = "http://yo.itsmytestclient.net/callback",
        _userinfo = "https://someone@yo.itsmytestclient.net/callback",
        _has_fragment = "https://yo.itsmytestclient.net/callback#hi",
        _doesnt_match_client_uri = "https://yo.itsmy-other-testclient.net/callback",
        _invalid_uri = "incoherent@none:sense/",
        _not_http = "https://localhost",
        _not_http = "https://127.0.0.1",
        _not_http = "https://[::1]",
        _has_port = "http://localhost:7455",
        _has_port = "http://127.0.0.1:8533",
        _has_port = "http://[::1]:34444",
        _incorrect_domain = "com.itsmytestclient:",
        _incorrect_domain = "net.itsmytestclients:",
        _incorrect_domain = "itsmytestclient.net:/",
        _incorrect_domain = "net.itsmytestclients.mobile.yo:",
        _has_authority = "net.itsmytestclient://",
        _has_authority = "net.itsmytestclient://itsmytestclients.net",
        _has_authority = "net.itsmytestclient://:6436",
        _has_authority = "net.itsmytestclient://asdf@"
      ]

      for invalid_uri <- invalid_redirect_uris do
        assert {:error, error} =
                 @valid_native_metadata
                 |> Map.update!("redirect_uris", &(&1 ++ [invalid_uri]))
                 |> Builtin.register_client()

        assert Enum.any?(
                 [
                   {:must_use_client_uri_as_base, "redirect_uris"},
                   {:invalid_redirect_uri, ":"},
                   :redirect_uri_is_not_a_string,
                   {:invalid_redirect_uri, %URI{}}
                 ],
                 &match?(&1, error)
               )
      end

      invalid_params = [
        {"redirect_uris", :delete},
        {"redirect_uris", "notalist"},
        {"application_type", "unsupported"},
        {"client_uri", "http://itsmytestclient.net"},
        {"client_uri", "https://someone@itsmytestclient.net"},
        {"client_uri", "incoherent@none:sense/"},
        {"client_uri", :delete},
        {"grant_types", []},
        {"grant_types", ["authorization_code unsupported"]},
        {"grant_types", "notalist"},
        {"grant_types", :delete},
        {"logo_uri", "https://blahbalbhalbhasdfasdf.com/logo"},
        {"logo_uri", "http://itsmytestclient.net/logo"},
        {"logo_uri", "incoherent@none:sense/"},
        {"response_types", []},
        {"response_types", ["unsupported"]},
        {"response_types", "notalist"},
        {"response_types", :delete},
        {"token_endpoint_auth_method", "unsupported"},
        {"token_endpoint_auth_method", :delete}
      ]

      for {field_name, value_or_action} <- invalid_params do
        client_metadata =
          case value_or_action do
            :delete -> Map.delete(@valid_native_metadata, field_name)
            value -> Map.put(@valid_native_metadata, field_name, value)
          end

        assert {:error, error} = Builtin.register_client(client_metadata)

        assert Enum.any?(
                 [
                   :redirect_uris_not_a_list,
                   :missing_redirect_uris,
                   {:unsupported_application_type, "unsupported"},
                   {:invalid_client_uri, %URI{}},
                   {:invalid_client_uri, ":"},
                   :missing_client_uri,
                   :grant_types_not_a_list,
                   {:missing_required_grant_type, "refresh_token"},
                   :missing_grant_types,
                   {:must_use_client_uri_as_base, "logo_uri"},
                   {:invalid_extra_uri, %URI{}},
                   {:invalid_extra_uri, ":"},
                   :invalid_response_types,
                   {:missing_required_response_type, "code"},
                   :missing_response_types,
                   :unsupported_token_endpoint_auth_method
                 ],
                 &match?(&1, error)
               )
      end
    end
  end

  describe "validate_authz_code_grant_params/1" do
    test "parses valid initial authorization code grant params" do
      {:ok, %DynamicOAuth2Client{client_id: client_id} = client_metadata} = Builtin.register_client(@valid_web_metadata)

      code_verifier = 24 |> :crypto.strong_rand_bytes() |> Base.encode64()
      code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
      device_id = Fixtures.device_id()

      stable_scope = "urn:matrix:client:api:* urn:matrix:client:device:#{device_id}"

      msc2967_scope =
        "urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:#{device_id}"

      state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      for response_mode <- ~w|fragment query|,
          redirect_uri <- client_metadata.redirect_uris,
          scope <- [stable_scope, msc2967_scope],
          prompt <- [nil, "create"] do
        redirect_uri = to_string(redirect_uri)

        params = %{
          "client_id" => client_id,
          "scope" => scope,
          "redirect_uri" => redirect_uri,
          "response_mode" => response_mode,
          "state" => state,
          "response_type" => "code",
          "code_challenge" => code_challenge,
          "code_challenge_method" => "S256",
          "prompt" => prompt
        }

        expected_prompt =
          case prompt do
            nil -> :login
            "create" -> :create
          end

        assert {:ok,
                %{
                  client_id: ^client_id,
                  state: ^state,
                  redirect_uri: ^redirect_uri,
                  response_mode: ^response_mode,
                  code_challenge: ^code_challenge,
                  scope: %{device_id: ^device_id, cs_api: [:read, :write]},
                  prompt: ^expected_prompt
                }} =
                 Builtin.validate_authz_code_grant_params(params)
      end
    end

    test "rejects invalid params" do
      {:ok, %DynamicOAuth2Client{client_id: client_id} = client_metadata} = Builtin.register_client(@valid_web_metadata)

      code_verifier = 24 |> :crypto.strong_rand_bytes() |> Base.encode64()
      code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
      device_id = Fixtures.device_id()

      stable_scope = "urn:matrix:client:api:* urn:matrix:client:device:#{device_id}"

      msc2967_scope =
        "urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:#{device_id}"

      state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      invalid_params = [
        {"client_id", :delete},
        {"client_id", "asdfasdfasdf"},
        {"scope", :delete},
        {"scope", "urn:unknown:scope"},
        {"scope", "urn:unknown:scope #{stable_scope |> String.split(" ") |> hd()}"},
        {"redirect_uri", :delete},
        {"redirect_uri", "https://some.randomasswebsite.com"},
        {"state", :delete},
        {"response_mode", "unsupported"},
        {"response_type", :delete},
        {"response_type", "unsupported"},
        {"code_challenge", :delete},
        {"code_challenge_method", :delete},
        {"code_challenge_method", "unsupported"},
        {"prompt", "unsupported"}
      ]

      for {field_name, value_or_action} <- invalid_params,
          response_mode <- ~w|fragment query|,
          redirect_uri <- client_metadata.redirect_uris,
          scope <- [stable_scope, msc2967_scope],
          prompt <- [nil, "create"] do
        redirect_uri = to_string(redirect_uri)

        params = %{
          "client_id" => client_id,
          "scope" => scope,
          "redirect_uri" => redirect_uri,
          "response_mode" => response_mode,
          "state" => state,
          "response_type" => "code",
          "code_challenge" => code_challenge,
          "code_challenge_method" => "S256",
          "prompt" => prompt
        }

        params =
          case value_or_action do
            :delete -> Map.delete(params, field_name)
            value -> Map.put(params, field_name, value)
          end

        assert {:error, error} = Builtin.validate_authz_code_grant_params(params)

        assert Enum.any?(
                 [
                   :missing_client_id,
                   :client_not_found,
                   :missing_scope,
                   :redirect_uri,
                   :state,
                   :response_mode,
                   :response_type,
                   :code_challenge,
                   :code_challenge_method,
                   :prompt
                 ],
                 &match?(&1, error)
               )
      end
    end
  end
end
