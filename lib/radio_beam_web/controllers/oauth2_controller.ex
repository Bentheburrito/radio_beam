defmodule RadioBeamWeb.OAuth2Controller do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 4]

  alias RadioBeam.OAuth2

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: RadioBeamWeb.Schemas.OAuth2] when action in [:get_token]
  plug RadioBeamWeb.Plugs.OAuth2.VerifyAccessToken when action == :whoami

  def get_auth_metadata(conn, _params), do: json(conn, OAuth2.metadata(conn.scheme, "#{conn.host}:#{conn.port}"))

  def register_client(conn, params) do
    case OAuth2.register_client(params) do
      {:ok, registered_params} -> json(conn, registered_params)
      {:error, error} -> conn |> put_status(400) |> json(registration_error(error))
    end
  end

  defp registration_error({:invalid_redirect_uri, invalid_substr}) do
    oauth_error(:invalid_redirect_uri, "Invalid redirect URI. Problematic substring: #{invalid_substr}")
  end

  defp registration_error(:redirect_uri_is_not_a_string) do
    oauth_error(:invalid_redirect_uri, "Invalid redirect URI. Not a string")
  end

  defp registration_error(:missing_redirect_uris) do
    oauth_error(:invalid_redirect_uri, "Missing redirect URI")
  end

  defp registration_error(:redirect_uris_not_a_list) do
    oauth_error(:invalid_redirect_uri, "Invalid redirect URIs. Expected a list of URIs")
  end

  defp registration_error({:must_use_client_uri_as_base, uris}) do
    oauth_error(:invalid_client_metadata, "Invalid #{uris}. All provided URIs must use the client URI as a base")
  end

  defp registration_error({error_desc_atom, reason}) do
    oauth_error(:invalid_client_metadata, "Invalid client metadata: #{error_desc_atom} '#{reason}'")
  end

  defp registration_error(error_desc_atom) do
    oauth_error(:invalid_client_metadata, "Invalid client metadata: #{error_desc_atom}")
  end

  def authenticate(%{method: "GET"} = conn, params) do
    case OAuth2.validate_authz_code_grant_params(params) do
      {:ok, bound_values} ->
        conn
        |> with_login_assigns(bound_values)
        |> put_session(:client_id, bound_values.client_id)
        |> put_session(:state, bound_values.state)
        |> put_session(:redirect_uri, bound_values.redirect_uri)
        |> put_session(:response_type, bound_values.response_type)
        |> put_session(:response_mode, bound_values.response_mode)
        |> put_session(:code_challenge, bound_values.code_challenge)
        |> put_session(:code_challenge_method, bound_values.code_challenge_method)
        |> put_session(:scope, bound_values.scope)
        |> put_session(:prompt, bound_values.prompt)
        |> render(:login)

      {:error, :client_not_found} ->
        conn
        |> assign(:errors, %{"Missing Client Registration" => "Clients are required to register with this homeserver."})
        |> render(:invalid_authz_grant_params)

      {:error, :redirect_uri} ->
        conn
        |> assign(:errors, %{
          "Unknown redirection URI" =>
            "The provided redirection URI does not match any URIs the client registered with."
        })
        |> render(:invalid_authz_grant_params)

      {:error, :state} ->
        error_params = oauth_error("invalid_request", "This homeserver requires a client-provided `state` value.")
        redirect_with(conn, URI.new!(params["redirect_uri"]), params["response_mode"], error_params)

      {:error, :registration_disabled} ->
        %{query_params: query_params} = fetch_query_params(conn)

        conn
        # drop "prompt" so we go to the login flow
        |> assign(:oauth_params, Map.delete(query_params, "prompt"))
        |> render(:registration_disabled)

      {:error, error} ->
        error_params = oauth_error("invalid_request", "#{inspect(error)}", params["state"])
        redirect_with(conn, URI.new!(params["redirect_uri"]), params["response_mode"] || "query", error_params)
    end
  end

  def authenticate(%{method: "POST"} = conn, %{"user_id_localpart" => localpart, "password" => password}) do
    user_id = "@#{localpart}:#{RadioBeam.server_name()}"

    case get_auth_params_from_session(conn) do
      {:ok, bound_values} ->
        case OAuth2.authenticate_user_by_password(user_id, password, bound_values) do
          {:ok, code} ->
            response_params = %{code: code, state: bound_values.state}
            redirect_with(conn, bound_values.redirect_uri, bound_values.response_mode, response_params)

          {:error, error} ->
            form_errors =
              case error do
                %{errors: [id: error]} -> [user_id_localpart: error]
                %{errors: [pwd_hash: {"password is too weak", _}]} -> [password: {OAuth2.weak_password_message(), []}]
                %{errors: [pwd_hash: error]} -> [password: error]
                :already_exists -> [user_id_localpart: {"That username is already taken.", []}]
                :unknown_username_or_password -> [user_id_localpart: {"Unknown username or password", []}]
              end

            conn
            |> with_login_assigns(bound_values, %{"user_id_localpart" => localpart, "password" => ""}, form_errors)
            |> render(:login)
        end

      {:error, :missing_values_in_session} ->
        conn
        |> assign(:errors, %{
          "Something went very wrong..." =>
            "We did not find your authentication information for this session. Please make sure you have cookies enabled."
        })
        |> render(:invalid_authz_grant_params)
    end
  end

  def authenticate(%{method: "POST"} = conn, _params) do
    json_error(conn, 400, :endpoint_error, [:invalid_param, "Missing user localpart or password"])
  end

  defp with_login_assigns(conn, bound_values, form_attrs \\ %{}, form_errors \\ []) do
    {:ok, client_metadata} = OAuth2.lookup_client(bound_values.client_id)

    oauth_params_to_swap_flow =
      bound_values
      |> Map.update!(:scope, &OAuth2.scope_to_urn/1)
      |> Map.update!(:redirect_uri, &to_string/1)

    oauth_params_to_swap_flow =
      case oauth_params_to_swap_flow do
        # flip the value of prompt, for when user presses "login/create
        # account instead", page reloads with desired flow
        %{prompt: :login} -> Map.put(oauth_params_to_swap_flow, :prompt, :create)
        %{prompt: :create} -> Map.delete(oauth_params_to_swap_flow, :prompt)
      end

    conn
    |> assign(:form, Phoenix.Component.to_form(form_attrs, errors: form_errors))
    |> assign(:submit_to, OAuth2.metadata(conn.scheme, "#{conn.host}:#{conn.port}").authorization_endpoint)
    |> assign(:server_name, RadioBeam.server_name())
    |> assign(:prompt, bound_values.prompt)
    |> assign(:client_name, client_metadata.client_name)
    |> assign(:scope, bound_values.scope)
    |> assign(:oauth_params_to_swap_flow, oauth_params_to_swap_flow)
  end

  def get_token(%{assigns: %{request: %{"grant_type" => "authorization_code"}}} = conn, _params) do
    %{"code" => code, "redirect_uri" => redirect_uri_str, "client_id" => client_id, "code_verifier" => code_verifier} =
      conn.assigns.request

    case OAuth2.exchange_authz_code_for_tokens(
           code,
           code_verifier,
           client_id,
           URI.new!(redirect_uri_str),
           [],
           conn.scheme,
           "#{conn.host}:#{conn.port}"
         ) do
      {:ok, access_token, refresh_token, scope, expires_in} ->
        json(conn, %{
          access_token: access_token,
          token_type: "Bearer",
          expires_in: expires_in,
          refresh_token: refresh_token,
          scope: scope
        })

      {:error, :invalid_grant} ->
        json_error(conn, 400, :endpoint_error, [
          "invalid_grant",
          "authorization grant is invalid, expired, revoked, or was already issued."
        ])

      {:error, error} ->
        Logger.error("Error exchanging an authz code: #{inspect(error)}")
        json_error(conn, 500, :unknown, "Something went very wrong")
    end
  end

  def get_token(%{assigns: %{request: %{"grant_type" => "refresh_token"}}} = conn, _params) do
    case OAuth2.refresh_token(conn.assigns.request["refresh_token"]) do
      {:ok, access_token, refresh_token, scope, expires_in} ->
        json(conn, %{
          access_token: access_token,
          token_type: "Bearer",
          expires_in: expires_in,
          refresh_token: refresh_token,
          scope: scope
        })

      {:error, :invalid_token} ->
        json_error(conn, 400, :endpoint_error, ["invalid_grant", "refresh token is invalid, expired, revoked."])

      {:error, error} ->
        Logger.error("Error exchanging an authz code: #{inspect(error)}")
        json_error(conn, 500, :unknown, "Something went very wrong")
    end
  end

  def revoke_token(conn, %{"token" => token}) do
    case OAuth2.revoke_token(token) do
      :ok -> json(conn, %{})
    end
  end

  def revoke_token(conn, _params) do
    conn |> put_status(400) |> json(oauth_error(:invalid_request, "No 'token' to revoke was provided"))
  end

  # TOIMPL: application service users
  def whoami(conn, _params) do
    json(conn, %{device_id: conn.assigns.session.device.id, is_guest: false, user_id: conn.assigns.session.user.id})
  end

  defp get_auth_params_from_session(conn) do
    case get_session(conn) do
      %{
        "client_id" => client_id,
        "state" => state,
        "redirect_uri" => redirect_uri_str,
        "response_type" => response_type,
        "response_mode" => response_mode,
        "code_challenge" => code_challenge,
        "code_challenge_method" => code_challenge_method,
        "scope" => scope,
        "prompt" => prompt
      } ->
        {:ok,
         %{
           client_id: client_id,
           state: state,
           redirect_uri: URI.new!(redirect_uri_str),
           response_type: response_type,
           response_mode: response_mode,
           code_challenge: code_challenge,
           code_challenge_method: code_challenge_method,
           scope: scope,
           prompt: prompt
         }}

      _else ->
        {:error, :missing_values_in_session}
    end
  end

  defp redirect_with(conn, redirect_uri, response_mode, response_params) do
    populated_redirect_uri =
      case response_mode do
        "query" -> URI.append_query(redirect_uri, URI.encode_query(response_params))
        "fragment" -> %URI{redirect_uri | fragment: URI.encode_query(response_params)}
      end

    redirect(conn, external: to_string(populated_redirect_uri))
  end

  defp oauth_error(error, description, state), do: error |> oauth_error(description) |> Map.put(:state, state)
  defp oauth_error(error, description), do: %{error: error, error_description: description}
end
