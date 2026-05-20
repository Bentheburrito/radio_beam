defmodule RadioBeamWeb.AccountController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 4]
  import RadioBeamWeb.AccountHTML, only: [fmt_unix: 1]

  alias RadioBeam.Errors
  alias RadioBeam.User
  alias RadioBeam.User.Authentication.OAuth2
  alias RadioBeamWeb.Schemas.Account, as: AccountSchema

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: AccountSchema] when action in ~w|put_tag|a

  def get_config(%{assigns: %{user_id: user_id}} = conn, %{"user_id" => user_id, "type" => type} = params) do
    scope = Map.get(params, "room_id", :global)

    with {:ok, account_data} <- User.get_account_data(user_id),
         data when not is_nil(data) <- get_in(account_data, [scope, type]) do
      json(conn, data)
    else
      _nil_or_not_found_tuple ->
        conn
        |> put_status(404)
        |> json(Errors.not_found("No '#{type}' #{scope} account data has been provided for this user"))
    end
  end

  def get_config(conn, _params) do
    conn |> put_status(403) |> json(Errors.forbidden("You cannot get account data for other users"))
  end

  def put_config(%{assigns: %{user_id: user_id}} = conn, %{"user_id" => user_id, "type" => type} = params) do
    with content when is_map(content) <- conn.body_params,
         :ok <- User.put_account_data(user_id, Map.get(params, "room_id", :global), type, content) do
      json(conn, %{})
    else
      {:error, :invalid_room_id} ->
        conn |> put_status(400) |> json(Errors.endpoint_error(:invalid_param, "Not a valid room ID"))

      {:error, :invalid_type} ->
        conn |> put_status(405) |> json(Errors.bad_json("Cannot set #{type} through this API"))

      _bad_content ->
        conn |> put_status(400) |> json(Errors.bad_json("Request body must be JSON"))
    end
  end

  def put_config(conn, _params) do
    conn |> put_status(403) |> json(Errors.forbidden("You cannot put account data for other users"))
  end

  def put_tag(conn, %{"room_id" => room_id, "tag" => tag}) do
    user_id = conn.assigns.user_id
    order = Map.fetch!(conn.assigns.request, "order")

    case User.put_room_tag(user_id, room_id, tag, order) do
      :ok -> json(conn, %{})
      {:error, :invalid_room_id} -> json_error(conn, 400, :endpoint_error, [:invalid_param, "invalid room ID"])
    end
  end

  def get_tags(conn, %{"room_id" => room_id}), do: json(conn, User.get_room_tags(conn.assigns.user_id, room_id))

  def delete_tag(conn, %{"room_id" => room_id, "tag" => tag}) do
    user_id = conn.assigns.user_id

    case User.delete_room_tag(user_id, room_id, tag) do
      :ok -> json(conn, %{})
      {:error, :invalid_room_id} -> json_error(conn, 400, :endpoint_error, [:invalid_param, "invalid room ID"])
    end
  end

  def login(conn, _params) do
    base_url = "https://#{conn.host}:#{conn.port}"
    redirect_uri = "#{base_url}/account/callback"

    {:ok, client} =
      OAuth2.register_client(%{
        "application_type" => "web",
        "client_name" => "RadioBeam Local Account Management on #{RadioBeam.server_name()}",
        "client_uri" => base_url,
        "grant_types" => ["authorization_code", "refresh_token"],
        "redirect_uris" => [redirect_uri],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      })

    state = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    code_verifier = 24 |> :crypto.strong_rand_bytes() |> Base.encode64()
    code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)
    device_id = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    oauth2_query_params = %{
      client_id: client.client_id,
      scope: OAuth2.scope_to_urn(account: [:read, :write], device_id: device_id),
      state: state,
      redirect_uri: redirect_uri,
      response_type: "code",
      response_mode: "query",
      code_challenge: code_challenge,
      code_challenge_method: :S256
    }

    conn
    |> put_session(:am_client, client.client_id)
    |> put_session(:am_state, state)
    |> put_session(:am_verifier, code_verifier)
    |> put_session(:am_redirect_uri_str, to_string(redirect_uri))
    |> redirect(to: ~p"/oauth2/auth?#{oauth2_query_params}")
  end

  def home(conn, _params) do
    conn
    |> assign(:server_name, RadioBeam.server_name())
    |> assign(:user_id, conn.assigns.user_id)
    |> assign(:device_id, conn.assigns.device_id)
    |> assign(:devices, User.get_all_device_info(conn.assigns.user_id))
    |> render(:home)
  end

  def update_device_name(conn, %{"device" => device_id, "new_display_name" => display_name}) do
    User.put_device_display_name(conn.assigns.user_id, device_id, display_name)

    redirect(conn, to: ~p"/account")
  end

  def logout(conn, %{"device" => device_id}) do
    :ok = User.delete_device(conn.assigns.user_id, device_id)

    redirect(conn, to: ~p"/account")
  end

  def logout(conn, _params) do
    with %{"access_token" => token} <- get_session(conn) do
      OAuth2.revoke_token(token)
      :ok = User.delete_device(conn.assigns.user_id, conn.assigns.device_id)
    end

    conn
    |> clear_session()
    |> login(%{})
  end

  def callback(conn, %{"code" => authz_code, "state" => state}) do
    case get_session(conn) do
      %{
        "am_client" => client_id,
        "am_state" => ^state,
        "am_verifier" => code_verifier,
        "am_redirect_uri_str" => redirect_uri_str
      } ->
        display_name = "Account Management browser session (created at #{fmt_unix(RadioBeam.Time.now())})"

        case OAuth2.exchange_authz_code_for_tokens(
               authz_code,
               code_verifier,
               client_id,
               URI.new!(redirect_uri_str),
               [display_name: display_name],
               conn.scheme,
               "#{conn.host}:#{conn.port}"
             ) do
          {:ok, access_token, refresh_token, _scope, expires_in} ->
            conn
            |> clear_session()
            |> put_session(:access_token, access_token)
            |> put_session(:refresh_token, refresh_token)
            |> put_session(:expires_at, DateTime.add(DateTime.utc_now(), expires_in, :second))
            |> redirect(to: ~p"/account")

          {:error, reason} ->
            conn
            |> put_flash(:error, "Could not log in, reason: #{inspect(reason)}")
            |> login(%{})
        end

      %{} ->
        conn
        |> put_flash(:error, "Could not log in, reason: invalid or missing OAuth2 callback parameters.")
        |> login(%{})
    end
  end
end
