defmodule RadioBeamWeb.Router do
  use RadioBeamWeb, :router

  alias RadioBeamWeb.AccountController
  alias RadioBeamWeb.AuthController
  alias RadioBeamWeb.ClientController
  alias RadioBeamWeb.ContentRepoController
  alias RadioBeamWeb.FilterController
  alias RadioBeamWeb.HomeserverInfoController
  alias RadioBeamWeb.KeysController
  alias RadioBeamWeb.OAuth2Controller
  alias RadioBeamWeb.RelationsController
  alias RadioBeamWeb.RoomController
  alias RadioBeamWeb.RoomKeysController
  alias RadioBeamWeb.SyncController

  @cs_api_cors %{
    "access-control-allow-origin" => "*",
    "access-control-allow-methods" => "GET, POST, PUT, DELETE, OPTIONS",
    "access-control-allow-headers" => "X-Requested-With, Content-Type, Authorization"
  }

  pipeline :cs_api do
    plug :accepts, ["json"]
    plug :put_secure_browser_headers, @cs_api_cors
  end

  pipeline :auth_cs_api do
    plug :cs_api
    plug RadioBeamWeb.Plugs.OAuth2.VerifyAccessToken
  end

  pipeline :oauth2_authz_code_grant do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RadioBeamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  get "/", HomeserverInfoController, :home
  get "/.well-known/matrix/client", HomeserverInfoController, :well_known_client

  scope "/oauth2" do
    pipe_through :cs_api

    post "/clients/register", OAuth2Controller, :register_client
    post "/token", OAuth2Controller, :get_token
    post "/revoke", OAuth2Controller, :revoke_token
  end

  scope "/oauth2" do
    pipe_through :oauth2_authz_code_grant

    get "/auth", OAuth2Controller, :authenticate
    post "/auth", OAuth2Controller, :authenticate
  end

  ### LEGACY AUTH API - DEPRECATED ###
  scope "/_matrix" do
    pipe_through :cs_api

    scope "/client" do
      scope "/v3" do
        get "/login", HomeserverInfoController, :login_types
        post "/login", AuthController, :login
        post "/register", AuthController, :register
        post "/refresh", AuthController, :refresh
      end
    end
  end

  ### AUTHENTICATED CS-API ENDPOINTS ###
  scope "/_matrix" do
    pipe_through :auth_cs_api

    # these will be deprecated in the future
    scope "/media" do
      post "/v1/create", ContentRepoController, :create
      post "/v3/upload", ContentRepoController, :upload
      put "/v3/upload/:server_name/:media_id", ContentRepoController, :upload
    end

    scope "/client" do
      scope "/v1" do
        get "/media/config", ContentRepoController, :config
        get "/media/download/:server_name/:media_id/:filename", ContentRepoController, :download
        get "/media/download/:server_name/:media_id", ContentRepoController, :download
        get "/media/thumbnail/:server_name/:media_id", ContentRepoController, :thumbnail

        get "/rooms/:room_id/relations/:event_id", RelationsController, :get_children
        get "/rooms/:room_id/relations/:event_id/:rel_type", RelationsController, :get_children
        get "/rooms/:room_id/relations/:event_id/:rel_type/:event_type", RelationsController, :get_children
      end

      scope "/v3" do
        get "/capabilities", HomeserverInfoController, :capabilities

        get "/devices", ClientController, :get_device
        get "/devices/:device_id", ClientController, :get_device
        put "/devices/:device_id", ClientController, :put_device_display_name

        get "/sync", SyncController, :sync

        post "/createRoom", RoomController, :create
        get "/joined_rooms", RoomController, :joined

        put "/sendToDevice/:type/:transaction_id", ClientController, :send_to_device

        scope "/keys" do
          get "/changes", KeysController, :changes
          post "/claim", KeysController, :claim
          post "/device_signing/upload", KeysController, :upload_cross_signing
          post "/query", KeysController, :query
          post "/signatures/upload", KeysController, :upload_signatures
          post "/upload", KeysController, :upload
        end

        scope "/room_keys" do
          get "/keys", RoomKeysController, :get_keys
          get "/keys/:room_id", RoomKeysController, :get_keys
          get "/keys/:room_id/:session_id", RoomKeysController, :get_keys
          put "/keys", RoomKeysController, :put_keys
          put "/keys/:room_id", RoomKeysController, :put_keys
          put "/keys/:room_id/:session_id", RoomKeysController, :put_keys
          delete "/keys", RoomKeysController, :delete_keys
          delete "/keys/:room_id", RoomKeysController, :delete_keys
          delete "/keys/:room_id/:session_id", RoomKeysController, :delete_keys

          post "/version", RoomKeysController, :create_backup
          get "/version", RoomKeysController, :get_backup_info
          get "/version/:version", RoomKeysController, :get_backup_info
          put "/version/:version", RoomKeysController, :put_backup_auth_data
          delete "/version/:version", RoomKeysController, :delete_backup
        end

        scope "/rooms" do
          post "/:room_id/invite", RoomController, :invite
          post "/:room_id/join", RoomController, :join
          post "/:room_id/leave", RoomController, :leave
          # TOIMPL:
          # post "/:room_id/forget", RoomController, :forget
          # post "/:room_id/kick", RoomController, :kick
          # post "/:room_id/ban", RoomController, :ban
          # post "/:room_id/unban", RoomController, :unban

          put "/:room_id/send/:event_type", RoomController, :send
          put "/:room_id/send/:event_type/:transaction_id", RoomController, :send
          put "/:room_id/state/:event_type/:state_key", RoomController, :put_state
          put "/:room_id/state/:event_type", RoomController, :put_state

          put "/:room_id/redact/:event_id/:transaction_id", RoomController, :redact

          get "/:room_id/event/:event_id", RoomController, :get_event
          get "/:room_id/joined_members", RoomController, :get_joined_members
          get "/:room_id/members", RoomController, :get_members
          get "/:room_id/state", RoomController, :get_state
          get "/:room_id/state/:event_type/:state_key", RoomController, :get_state_event
          get "/:room_id/state/:event_type", RoomController, :get_state_event
          get "/:room_id/messages", SyncController, :get_messages
          get "/:room_id/timestamp_to_event", RoomController, :get_nearest_event

          put "/:room_id/typing/:user_id", RoomController, :put_typing
        end

        scope "/account" do
          get "/whoami", OAuth2Controller, :whoami
        end

        scope "/user/:user_id" do
          post "/filter", FilterController, :put
          get "/filter/:filter_id", FilterController, :get

          get "/account_data/:type", AccountController, :get_config
          put "/account_data/:type", AccountController, :put_config
          get "/rooms/:room_id/account_data/:type", AccountController, :get_config
          put "/rooms/:room_id/account_data/:type", AccountController, :put_config
        end

        post "/join/:room_id_or_alias", RoomController, :join
        # TOIMPL:
        # post "/knock/:room_id_or_alias", RoomController, :knock
      end
    end
  end

  ### UNAUTHENTICATED CS-API ENDPOINTS ###
  scope "/_matrix" do
    pipe_through :cs_api

    scope "/client" do
      get "/versions", HomeserverInfoController, :versions

      scope "/v1" do
        get "/auth_metadata", OAuth2Controller, :get_auth_metadata
      end
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:radio_beam, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: RadioBeamWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
