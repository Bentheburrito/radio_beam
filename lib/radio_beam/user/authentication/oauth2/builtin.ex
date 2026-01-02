defmodule RadioBeam.User.Authentication.OAuth2.Builtin do
  @moduledoc """
  A minimal, built-in OAuth 2.0 authorization server for Matrix clients.
  """
  @behaviour RadioBeam.User.Authentication.OAuth2

  alias RadioBeam.User.Authentication.OAuth2.Builtin.AuthzCodeCache
  alias RadioBeam.User.Authentication.OAuth2.Builtin.DynamicOAuth2Client
  alias RadioBeam.User.Authentication.OAuth2.Builtin.Guardian
  alias RadioBeam.User
  alias RadioBeam.User.Database
  alias RadioBeam.User.Device
  alias RadioBeam.User.LocalAccount

  @required_grant_types ["authorization_code", "refresh_token"]
  @num_code_gen_bytes 32

  @impl RadioBeam.User.Authentication.OAuth2
  def metadata do
    %{
      code_challenge_methods_supported: ["S256"],
      grant_types_supported: @required_grant_types,
      prompt_values_supported: ["create"],
      response_modes_supported: ["query", "fragment"],
      response_types_supported: ["code"]
    }
  end

  @impl RadioBeam.User.Authentication.OAuth2
  def register_client(client_metadata_attrs) do
    with {:ok, app_type} <- validate_appliation_type(client_metadata_attrs),
         {:ok, %URI{} = client_uri} <- validate_client_uri(client_metadata_attrs),
         {:ok, grant_types} <- validate_grant_types(client_metadata_attrs),
         {:ok, logo_uri} <- validate_extra_uri(client_metadata_attrs, client_uri, "logo_uri"),
         {:ok, policy_uri} <- validate_extra_uri(client_metadata_attrs, client_uri, "policy_uri"),
         {:ok, redirect_uris} <- validate_redirect_uris(client_metadata_attrs, client_uri, app_type),
         {:ok, response_types} <- validate_response_types(client_metadata_attrs),
         {:ok, :none} <- validate_token_endpoint_auth_method(client_metadata_attrs),
         {:ok, tos_uri} <- validate_extra_uri(client_metadata_attrs, client_uri, "tos_uri") do
      client =
        DynamicOAuth2Client.new!(%{
          application_type: app_type,
          client_name: Map.get(client_metadata_attrs, "client_name", "A Matrix Client (name not provided)"),
          client_uri: client_uri,
          grant_types: grant_types,
          logo_uri: logo_uri,
          policy_uri: policy_uri,
          redirect_uris: redirect_uris,
          response_types: response_types,
          token_endpoint_auth_method: :none,
          tos_uri: tos_uri
        })

      with :ok <- Database.upsert_oauth2_client(client) do
        {:ok, client}
      end
    end
  end

  defp validate_appliation_type(client_metadata_attrs) do
    case Map.get(client_metadata_attrs, "application_type", "web") do
      app_type when app_type in ~w|web native| -> {:ok, app_type}
      unsupported_app_type -> {:error, {:unsupported_application_type, unsupported_app_type}}
    end
  end

  defp validate_client_uri(client_metadata_attrs) do
    case Map.fetch(client_metadata_attrs, "client_uri") do
      {:ok, client_uri_str} ->
        case URI.new(client_uri_str) do
          {:ok, %URI{scheme: "https", userinfo: nil, host: "" <> _} = client_uri} -> {:ok, client_uri}
          {:ok, %URI{} = invalid_uri} -> {:error, {:invalid_client_uri, invalid_uri}}
          {:error, invalid_substr} -> {:error, {:invalid_client_uri, invalid_substr}}
        end

      :error ->
        {:error, :missing_client_uri}
    end
  end

  defp validate_grant_types(client_metadata_attrs) do
    case Map.fetch(client_metadata_attrs, "grant_types") do
      {:ok, grant_types} when not is_list(grant_types) ->
        {:error, :grant_types_not_a_list}

      {:ok, grant_types} ->
        case Enum.find(@required_grant_types, &(&1 not in grant_types)) do
          nil -> {:ok, @required_grant_types}
          missing_grant_type -> {:error, {:missing_required_grant_type, missing_grant_type}}
        end

      :error ->
        {:error, :missing_grant_types}
    end
  end

  defp validate_extra_uri(client_metadata_attrs, %URI{} = client_uri, uri_field_name) do
    case Map.fetch(client_metadata_attrs, uri_field_name) do
      {:ok, uri_str} ->
        case URI.new(uri_str) do
          {:ok, %URI{scheme: "https", userinfo: nil, host: host} = uri} ->
            if String.ends_with?(host, client_uri.host),
              do: {:ok, uri},
              else: {:error, {:must_use_client_uri_as_base, uri_field_name}}

          {:ok, %URI{} = invalid_uri} ->
            {:error, {:invalid_extra_uri, invalid_uri}}

          {:error, invalid_substr} ->
            {:error, {:invalid_extra_uri, invalid_substr}}
        end

      :error ->
        # extra URIs are optional, return nil if not present
        {:ok, nil}
    end
  end

  defp validate_redirect_uris(client_metadata_attrs, client_uri, app_type) do
    case Map.fetch(client_metadata_attrs, "redirect_uris") do
      {:ok, redirect_uris} when is_list(redirect_uris) ->
        redirect_uris
        |> Stream.map(&validate_redirect_uri(&1, client_uri, app_type))
        |> Enum.reduce_while({:ok, []}, fn
          {:error, _err} = error, _acc -> {:halt, error}
          {:ok, %URI{} = redirect_uri}, {:ok, validated_uris} -> {:cont, {:ok, [redirect_uri | validated_uris]}}
        end)

      {:ok, _invalid_redirect_uris} ->
        {:error, :redirect_uris_not_a_list}

      :error ->
        {:error, :missing_redirect_uris}
    end
  end

  defp validate_redirect_uri(invalid_redirect_uri, _client_uri, _app_type) when not is_binary(invalid_redirect_uri),
    do: {:error, :redirect_uri_is_not_a_string}

  defp validate_redirect_uri(redirect_uri_str, client_uri, "web") do
    case URI.new(redirect_uri_str) do
      {:ok, %URI{scheme: "https", userinfo: nil, host: host, fragment: nil} = redirect_uri} ->
        if String.ends_with?(host, client_uri.host),
          do: {:ok, redirect_uri},
          else: {:error, {:must_use_client_uri_as_base, "redirect_uris"}}

      {:ok, %URI{} = invalid_uri} ->
        {:error, {:invalid_redirect_uri, invalid_uri}}

      {:error, invalid_substr} ->
        {:error, {:invalid_redirect_uri, invalid_substr}}
    end
  end

  @loopback_hosts ~w|localhost 127.0.0.1 ::1|
  defp validate_redirect_uri(redirect_uri_str, %URI{} = client_uri, "native") do
    reverse_dns_client_uri_host = client_uri.host |> String.split(".") |> Enum.reverse() |> Enum.join(".")

    # have to use :uri_string specifically here, as URI.* functions will set a
    # default port based on the scheme (if present), even if no port is
    # actually specified. Rare Elixir stdlib L
    port_specified? =
      case :uri_string.parse(redirect_uri_str) do
        %{port: _} -> true
        _else -> false
      end

    case URI.new(redirect_uri_str) do
      {:ok,
       %URI{scheme: ^reverse_dns_client_uri_host <> "." <> _, userinfo: nil, host: nil, fragment: nil} = redirect_uri}
      when not port_specified? ->
        {:ok, redirect_uri}

      {:ok, %URI{scheme: ^reverse_dns_client_uri_host, userinfo: nil, host: nil, fragment: nil} = redirect_uri}
      when not port_specified? ->
        {:ok, redirect_uri}

      {:ok, %URI{scheme: "http", userinfo: nil, host: host, fragment: nil} = redirect_uri}
      when host in @loopback_hosts and not port_specified? ->
        {:ok, redirect_uri}

      {:ok, %URI{scheme: "https"} = _maybe_valid_web_redirect_uri} ->
        validate_redirect_uri(redirect_uri_str, client_uri, "web")

      {:ok, %URI{} = invalid_uri} ->
        {:error, {:invalid_redirect_uri, invalid_uri}}

      {:error, invalid_substr} ->
        {:error, {:invalid_redirect_uri, invalid_substr}}
    end
  end

  defp validate_response_types(client_metadata_attrs) do
    case Map.fetch(client_metadata_attrs, "response_types") do
      {:ok, response_types} when not is_list(response_types) ->
        {:error, :invalid_response_types}

      {:ok, response_types} ->
        if "code" in response_types do
          {:ok, ["code"]}
        else
          {:error, {:missing_required_response_type, "code"}}
        end

      :error ->
        {:error, :missing_response_types}
    end
  end

  defp validate_token_endpoint_auth_method(client_metadata_attrs) do
    if Map.get(client_metadata_attrs, "token_endpoint_auth_method") == "none",
      do: {:ok, :none},
      else: {:error, :unsupported_token_endpoint_auth_method}
  end

  @impl RadioBeam.User.Authentication.OAuth2
  def lookup_client(client_id) do
    with {:error, :not_found} <- Database.fetch_oauth2_client(client_id), do: {:error, :client_not_found}
  end

  @impl RadioBeam.User.Authentication.OAuth2
  def validate_authz_code_grant_params(params) do
    server_metadata = metadata()

    with client_id when is_binary(client_id) <- Map.get(params, "client_id", {:error, :missing_client_id}),
         {:ok, client_metadata} <- lookup_client(client_id),
         {:ok, scope} <- validate_scope(params) do
      redirect_uri =
        case URI.new!(params["redirect_uri"] || "") do
          # For "http [redirect] URI on the loopback interface" during client
          # registration, the spec says "There MUST NOT be a port. The
          # homeserver MUST then accept any port number during the
          # authorization flow."
          %URI{scheme: "http", host: host} = redirect_uri when host in @loopback_hosts -> put_in(redirect_uri.port, 80)
          %URI{} = redirect_uri -> redirect_uri
        end

      # https://openid.net/specs/oauth-v2-multiple-response-types-1_0.html#ResponseModes
      # "For purposes of this specification, the default Response Mode for the
      # OAuth 2.0 code Response Type is the query encoding"
      response_mode = Map.get(params, "response_mode", "query")

      cond do
        redirect_uri not in client_metadata.redirect_uris ->
          {:error, :redirect_uri}

        not is_binary(params["state"]) ->
          {:error, :state}

        response_mode not in server_metadata.response_modes_supported ->
          {:error, :response_mode}

        params["response_type"] not in client_metadata.response_types ->
          {:error, :response_type}

        not is_binary(params["code_challenge"]) ->
          {:error, :code_challenge}

        params["code_challenge_method"] not in server_metadata.code_challenge_methods_supported ->
          {:error, :code_challenge_method}

        :else ->
          with {:ok, prompt} <- parse_prompt(params["prompt"]) do
            {:ok,
             %{
               client_id: params["client_id"],
               state: params["state"],
               redirect_uri: params["redirect_uri"],
               response_type: params["response_type"],
               response_mode: response_mode,
               code_challenge: params["code_challenge"],
               code_challenge_method: params["code_challenge_method"],
               scope: scope,
               prompt: prompt
             }}
          end
      end
    end
  end

  defp validate_scope(%{"scope" => scope_str}) when is_binary(scope_str) do
    scope =
      scope_str
      |> String.split(" ")
      |> Enum.reduce({:ok, %{}}, fn scope, {:ok, validated_scope_map} ->
        case parse_scope(scope) do
          {:ok, {:cs_api, perms}} -> {:ok, Map.put(validated_scope_map, :cs_api, perms)}
          {:ok, {:device_id, device_id}} -> {:ok, Map.put(validated_scope_map, :device_id, device_id)}
          {:error, :unrecognized_scope} -> {:ok, validated_scope_map}
        end
      end)

    case scope do
      {:ok, %{device_id: "" <> _, cs_api: [:read, :write]}} -> scope
      _else -> {:error, :missing_scope}
    end
  end

  defp validate_scope(_params), do: {:error, :missing_scope}

  defp parse_scope("urn:matrix:client:api:*"), do: {:ok, {:cs_api, [:read, :write]}}

  defp parse_scope("urn:matrix:client:device:" <> device_id) do
    if Regex.match?(~r/^[a-zA-Z0-9\-\.~_]{10,}$/, device_id),
      do: {:ok, {:device_id, device_id}},
      else: {:error, :invalid_device_id}
  end

  # apparently the matrix Rust SDK is almost 6 months out of date (at the time
  # of writing), and does not forward the stable v1.15 scopes. So, we must
  # support the MSC 2967 scopes for clients that rely on the Rust SDK. Yikes.
  defp parse_scope("urn:matrix:org.matrix.msc2967.client:api:*"), do: parse_scope("urn:matrix:client:api:*")

  defp parse_scope("urn:matrix:org.matrix.msc2967.client:device:" <> device_id) do
    parse_scope("urn:matrix:client:device:" <> device_id)
  end

  defp parse_scope(_), do: {:error, :unrecognized_scope}

  defp parse_prompt("create") do
    if Application.get_env(:radio_beam, :registration_enabled, false),
      do: {:ok, :create},
      else: {:error, :registration_disabled}
  end

  defp parse_prompt(nil), do: {:ok, :login}
  defp parse_prompt(_unrecognized_prompt), do: {:error, :prompt}

  @impl RadioBeam.User.Authentication.OAuth2
  def authenticate_user_by_password(user_id, password, code_grant_values) do
    case Database.fetch_user_account(user_id) do
      {:ok, %LocalAccount{} = user_account} ->
        if Argon2.verify_pass(password, user_account.pwd_hash) do
          create_authz_code(user_id, code_grant_values)
        else
          {:error, :unknown_username_or_password}
        end

      {:error, :not_found} ->
        User.LocalAccount.no_user_verify()
        {:error, :unknown_username_or_password}
    end
  end

  defp create_authz_code(user_id, %{
         code_challenge: code_challenge,
         client_id: client_id,
         redirect_uri: redirect_uri,
         scope: scope
       }) do
    code = @num_code_gen_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64()

    with :ok <- AuthzCodeCache.put(code, code_challenge, client_id, redirect_uri, user_id, scope) do
      {:ok, code}
    end
  end

  @impl RadioBeam.User.Authentication.OAuth2
  def exchange_authz_code_for_tokens(
        code,
        code_verifier,
        client_id,
        %URI{} = redirect_uri,
        %URI{} = issuer,
        opts
      ) do
    {scope_to_urn, device_opts} = Keyword.pop!(opts, :scope_to_urn)

    with {:ok, user_id, scope} <- AuthzCodeCache.pop(code, code_verifier, client_id, redirect_uri),
         :ok <- create_device_if_not_exists(user_id, scope.device_id, device_opts),
         {:ok, result} <-
           Database.update_user_device_with(user_id, scope.device_id, &new_tokens(&1, scope, issuer, scope_to_urn)) do
      {access_token, refresh_token, scope, expires_in} = result
      {:ok, access_token, refresh_token, scope, expires_in}
    end
  end

  defp create_device_if_not_exists(user_id, device_id, on_new_opts) do
    user_id |> Device.new(device_id, on_new_opts) |> Database.insert_new_device()
    :ok
  end

  defp new_tokens(device, scope, issuer, scope_to_urn) do
    with {:ok, access_token, access_claims} <- new_access_token(device, scope, issuer, scope_to_urn),
         {:ok, refresh_token, refresh_claims} <- new_refresh_token(device, access_claims, issuer) do
      device = Device.rotate_token_ids(device, access_claims["jti"], refresh_claims["jti"])

      {:ok, device,
       {access_token, refresh_token, access_claims["scope"], access_claims["exp"] - System.os_time(:second)}}
    end
  end

  defp new_access_token(device, scope, issuer, scope_to_urn) do
    claims = %{scope: scope_to_urn.(scope)}
    opts = [token_type: "access", ttl: Application.fetch_env!(:radio_beam, :access_token_lifetime), issuer: issuer]

    with {:ok, access_token, claims} <- Guardian.encode_and_sign(device, claims, opts) do
      "access" = claims["typ"]
      {:ok, access_token, claims}
    end
  end

  defp new_refresh_token(device, %{"jti" => access_token_id, "scope" => scope}, issuer) do
    claims = %{scope: scope, access_token_id: access_token_id}
    opts = [token_type: "refresh", ttl: Application.fetch_env!(:radio_beam, :refresh_token_lifetime), issuer: issuer]

    with {:ok, refresh_token, claims} <- Guardian.encode_and_sign(device, claims, opts) do
      "refresh" = claims["typ"]
      {:ok, refresh_token, claims}
    end
  end

  @impl RadioBeam.User.Authentication.OAuth2
  def authenticate_user_by_access_token(token, device_ip) do
    with {:ok, %{"sub" => composite_id} = claims} <- Guardian.decode_and_verify(token),
         {:ok, user_id, device_id} <- Guardian.parse_composite_id(composite_id) do
      Database.update_user_device_with(user_id, device_id, fn %Device{} = device ->
        if claims["typ"] != "access" or claims["jti"] in device.revoked_unexpired_token_ids do
          {:error, :invalid_token}
        else
          perform_device_upkeep(device, device_ip)
        end
      end)
    end
  end

  defp perform_device_upkeep(%Device{} = device, device_ip) do
    device |> Device.put_last_seen_at(device_ip) |> Device.put_retryable_refresh_token_id(nil)
  end

  @impl RadioBeam.User.Authentication.OAuth2
  def refresh_token(refresh_token) do
    with {:ok, new_access_token, new_refresh_token, scope, expires_at} <- refresh_tokens(refresh_token) do
      {:ok, new_access_token, new_refresh_token, scope, expires_at - System.os_time(:second)}
    end
  end

  defp refresh_tokens(refresh_token) do
    access_opts = [ttl: Application.fetch_env!(:radio_beam, :access_token_lifetime)]

    with {:ok, old_claims, new_access_token, new_claims} <- exchange_for(refresh_token, "access", access_opts),
         {:ok, user_id, device_id} <- Guardian.parse_composite_id(old_claims["sub"]),
         {:ok, result} <-
           Database.update_user_device_with(user_id, device_id, &do_refresh(&1, refresh_token, old_claims, new_claims)) do
      {new_refresh_token, scope, expires_at} = result
      {:ok, new_access_token, new_refresh_token, scope, expires_at}
    end
  end

  defp exchange_for(token, token_type, opts) when token_type in ~w|access refresh| do
    with {:ok, {^token, old_claims}, {new_token, new_claims}} <- Guardian.exchange(token, "refresh", token_type, opts) do
      {:ok, old_claims, new_token, new_claims}
    end
  end

  defp do_refresh(device, refresh_token, old_claims, new_claims) do
    opts = [ttl: Application.fetch_env!(:radio_beam, :refresh_token_lifetime)]

    with :ok <- validate_unrevoked_or_retryable(device, old_claims),
         {:ok, _, new_refresh_token, %{"jti" => new_refresh_token_id}} <- exchange_for(refresh_token, "refresh", opts) do
      device =
        device
        |> Device.rotate_token_ids(new_claims["jti"], new_refresh_token_id)
        |> Device.put_retryable_refresh_token_id(old_claims["jti"])

      {:ok, device, {new_refresh_token, new_claims["scope"], new_claims["exp"]}}
    end
  end

  defp validate_unrevoked_or_retryable(device, claims) do
    cond do
      claims["typ"] != "refresh" ->
        {:error, :invalid_token}

      claims["jti"] in device.revoked_unexpired_token_ids and claims["jti"] != device.retryable_refresh_token_id ->
        {:error, :invalid_token}

      :else ->
        :ok
    end
  end

  @impl RadioBeam.User.Authentication.OAuth2
  def revoke_token(token) do
    case Guardian.resource_from_token(token) do
      {:ok, %Device{} = device, claims} ->
        if claims["jti"] in Map.values(device.last_issued_token_ids) do
          updater = fn device ->
            device
            |> Device.rotate_token_ids(nil, nil)
            |> Device.put_retryable_refresh_token_id(nil)
          end

          {:ok, _} = Database.update_user_device_with(device.user_id, device.id, updater)
          :ok
        else
          :ok
        end

      {:error, :token_expired} ->
        :ok

      {:error, :invalid_token} ->
        :ok
    end
  end
end
