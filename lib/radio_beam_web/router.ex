defmodule RadioBeamWeb.Router do
  use RadioBeamWeb, :router

  import RadioBeamWeb.Utils, only: [rl: 1]

  alias RadioBeamWeb.AccountController
  alias RadioBeamWeb.AdminController
  alias RadioBeamWeb.LegacyAuthAPIController
  alias RadioBeamWeb.ClientController
  alias RadioBeamWeb.ContentRepoController
  alias RadioBeamWeb.FilterController
  alias RadioBeamWeb.HomeserverInfoController
  alias RadioBeamWeb.KeyStoreController
  alias RadioBeamWeb.OAuth2Controller
  alias RadioBeamWeb.RelationsController
  alias RadioBeamWeb.RoomController
  alias RadioBeamWeb.RoomKeysController
  alias RadioBeamWeb.SyncController

  alias RadioBeamWeb.Plugs

  @cs_api_cors %{
    "access-control-allow-origin" => "*",
    "access-control-allow-methods" => "GET, POST, PUT, DELETE, OPTIONS",
    "access-control-allow-headers" => "X-Requested-With, Content-Type, Authorization"
  }

  pipeline :api_headers do
    plug :accepts, ["json"]
    plug :put_secure_browser_headers, @cs_api_cors
  end

  pipeline :cs_api do
    plug :api_headers
    plug Plugs.RateLimit
  end

  pipeline :auth_cs_api do
    plug :api_headers
    plug Plugs.OAuth2.VerifyAccessToken
    plug Plugs.RateLimit
  end

  pipeline :oauth2_authz_code_grant do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RadioBeamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug Plugs.CSP
    plug Plugs.RateLimit
  end

  pipeline :user_account_management do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RadioBeamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug Plugs.CSP
    plug Plugs.OAuth2.VerifyAccessTokenCookie
    plug Plugs.RateLimit
  end

  scope [] do
    pipe_through :cs_api

    get "/", HomeserverInfoController, :home, rl(:heavily_restrict_ip)
    get "/.well-known/matrix/client", HomeserverInfoController, :well_known_client, rl(:unauth_static_read)
  end

  scope "/oauth2" do
    pipe_through :cs_api

    post "/clients/register", OAuth2Controller, :register_client, rl(:infrequent_bursts)

    post "/token", OAuth2Controller, :get_token, rl(:infrequent_bursts)
    post "/revoke", OAuth2Controller, :revoke_token, rl(:infrequent_bursts)
  end

  scope "/oauth2" do
    pipe_through :oauth2_authz_code_grant

    get "/auth", OAuth2Controller, :authenticate, rl(:infrequent_bursts)
    post "/auth", OAuth2Controller, :authenticate, rl(:infrequent_bursts)
  end

  scope "/account" do
    pipe_through :user_account_management

    get "/", AccountController, :home, rl(:frequent_cheap)
    get "/login", AccountController, :login, rl(:infrequent_bursts)
    get "/callback", AccountController, :callback, rl(:infrequent_bursts)
    post "/logout", AccountController, :logout, rl(:infrequent_bursts)
    post "/update_device_name", AccountController, :update_device_name, rl(:infrequent_bursts)
  end

  ### LEGACY AUTH API - DEPRECATED ###
  scope "/_matrix" do
    pipe_through :cs_api

    scope "/client" do
      scope "/v3" do
        get "/login", HomeserverInfoController, :login_types, rl(:infrequent_bursts)
        post "/login", LegacyAuthAPIController, :login, rl(:infrequent_bursts)
        post "/register", LegacyAuthAPIController, :register, rl(:infrequent_bursts)
        post "/refresh", LegacyAuthAPIController, :refresh, rl(:infrequent_bursts)
      end
    end
  end

  ### AUTHENTICATED CS-API ENDPOINTS ###
  scope "/_matrix" do
    pipe_through :auth_cs_api

    # these will be deprecated in the future
    scope "/media" do
      post "/v1/create", ContentRepoController, :create, rl(:exp_write)
      post "/v3/upload", ContentRepoController, :upload, rl(:exp_write)

      put "/v3/upload/:server_name/:media_id", ContentRepoController, :upload, rl(:exp_write)
    end

    scope "/client" do
      scope "/v1" do
        scope "/media" do
          get "/config", ContentRepoController, :config, rl(:infrequent_bursts)
          get "/download/:server_name/:media_id/:filename", ContentRepoController, :download, rl(:infrequent_bursts)
          get "/download/:server_name/:media_id", ContentRepoController, :download, rl(:infrequent_bursts)
          get "/thumbnail/:server_name/:media_id", ContentRepoController, :thumbnail, rl(:infrequent_bursts)
        end

        get "/rooms/:room_id/threads", RelationsController, :get_threads, rl(:frequent_cheap)

        scope "/rooms/:room_id/relations" do
          get "/:event_id", RelationsController, :get_children, rl(:user_sync)
          get "/:event_id/:rel_type", RelationsController, :get_children, rl(:user_sync)
          get "/:event_id/:rel_type/:event_type", RelationsController, :get_children, rl(:user_sync)
        end

        scope "/admin" do
          put "/lock/:user_id", AdminController, :change_account_lock, rl(:admin)
          get "/lock/:user_id", AdminController, :check_account_lock, rl(:admin)
          put "/suspend/:user_id", AdminController, :change_account_suspension, rl(:admin)
          get "/suspend/:user_id", AdminController, :check_account_suspension, rl(:admin)
        end
      end

      scope "/v3" do
        get "/admin/whois/:user_id", AdminController, :whois, rl(:admin)

        get "/capabilities", HomeserverInfoController, :capabilities, rl(:frequent_cheap)

        get "/devices", ClientController, :get_device, rl(:frequent_cheap)
        get "/devices/:device_id", ClientController, :get_device, rl(:frequent_cheap)
        put "/devices/:device_id", ClientController, :put_device_display_name, rl(:frequent_cheap)

        get "/sync", SyncController, :sync, rl(:user_sync)

        post "/createRoom", RoomController, :create, rl(:exp_write)
        get "/joined_rooms", RoomController, :joined, rl(:infrequent_bursts)

        put "/sendToDevice/:type/:transaction_id", ClientController, :send_to_device, rl(:infrequent_bursts)

        scope "/keys" do
          get "/changes", KeyStoreController, :changes, rl(:infrequent_bursts)
          post "/claim", KeyStoreController, :claim, rl(:infrequent_bursts)
          post "/device_signing/upload", KeyStoreController, :upload_cross_signing, rl(:infrequent_bursts)
          post "/query", KeyStoreController, :query, rl(:infrequent_bursts)
          post "/signatures/upload", KeyStoreController, :upload_signatures, rl(:infrequent_bursts)
          post "/upload", KeyStoreController, :upload, rl(:infrequent_bursts)
        end

        scope "/room_keys" do
          get "/keys", RoomKeysController, :get_keys, rl(:frequent_cheap)
          get "/keys/:room_id", RoomKeysController, :get_keys, rl(:frequent_cheap)
          get "/keys/:room_id/:session_id", RoomKeysController, :get_keys, rl(:frequent_cheap)
          put "/keys", RoomKeysController, :put_keys, rl(:infrequent_bursts)
          put "/keys/:room_id", RoomKeysController, :put_keys, rl(:infrequent_bursts)
          put "/keys/:room_id/:session_id", RoomKeysController, :put_keys, rl(:infrequent_bursts)
          delete "/keys", RoomKeysController, :delete_keys, rl(:infrequent_bursts)
          delete "/keys/:room_id", RoomKeysController, :delete_keys, rl(:infrequent_bursts)
          delete "/keys/:room_id/:session_id", RoomKeysController, :delete_keys, rl(:infrequent_bursts)

          post "/version", RoomKeysController, :create_backup, rl(:infrequent_bursts)
          get "/version", RoomKeysController, :get_backup_info, rl(:frequent_cheap)
          get "/version/:version", RoomKeysController, :get_backup_info, rl(:infrequent_bursts)
          put "/version/:version", RoomKeysController, :put_backup_auth_data, rl(:infrequent_bursts)
          delete "/version/:version", RoomKeysController, :delete_backup, rl(:infrequent_bursts)
        end

        scope "/rooms" do
          post "/:room_id/invite", RoomController, :invite, rl(:infrequent_bursts)
          post "/:room_id/join", RoomController, :join, rl(:infrequent_bursts)
          post "/:room_id/leave", RoomController, :leave, rl(:infrequent_bursts)
          post "/:room_id/kick", RoomController, :kick, rl(:admin)
          post "/:room_id/ban", RoomController, :ban, rl(:admin)
          post "/:room_id/unban", RoomController, :unban, rl(:admin)
          # TOIMPL:
          # post "/:room_id/forget", RoomController, :forget

          put "/:room_id/send/:event_type", RoomController, :send, rl(:infrequent_bursts)
          put "/:room_id/send/:event_type/:transaction_id", RoomController, :send, rl(:infrequent_bursts)
          put "/:room_id/state/:event_type/:state_key", RoomController, :put_state, rl(:infrequent_bursts)
          put "/:room_id/state/:event_type", RoomController, :put_state, rl(:infrequent_bursts)

          put "/:room_id/redact/:event_id/:transaction_id", RoomController, :redact, rl(:admin)

          get "/:room_id/event/:event_id", RoomController, :get_event, rl(:infrequent_bursts)
          get "/:room_id/joined_members", RoomController, :get_joined_members, rl(:infrequent_bursts)
          get "/:room_id/members", RoomController, :get_members, rl(:infrequent_bursts)
          get "/:room_id/state", RoomController, :get_state, rl(:infrequent_bursts)
          get "/:room_id/state/:event_type/:state_key", RoomController, :get_state_event, rl(:infrequent_bursts)
          get "/:room_id/state/:event_type", RoomController, :get_state_event, rl(:infrequent_bursts)
          get "/:room_id/messages", SyncController, :get_messages, rl(:user_sync)
          get "/:room_id/timestamp_to_event", RoomController, :get_nearest_event, rl(:infrequent_bursts)
          get "/:room_id/context/:event_id", SyncController, :get_event_context, rl(:infrequent_bursts)

          put "/:room_id/typing/:user_id", RoomController, :put_typing, rl(:frequent_cheap)

          post "/:room_id/report", AdminController, :report_room, rl(:infrequent_bursts)
          post "/:room_id/report/:event_id", AdminController, :report_room_event, rl(:infrequent_bursts)

          post "/:room_id/upgrade", RoomController, :upgrade, rl(:infrequent_bursts)

          post "/:room_id/receipt/:type/:event_id", RoomController, :put_receipt, rl(:frequent_cheap)
        end

        scope "/users" do
          post "/:user_id/report", AdminController, :report_user, rl(:infrequent_bursts)
        end

        scope "/account" do
          get "/whoami", OAuth2Controller, :whoami, rl(:infrequent_bursts)
        end

        scope "/user/:user_id" do
          post "/filter", FilterController, :put, rl(:infrequent_bursts)
          get "/filter/:filter_id", FilterController, :get, rl(:infrequent_bursts)

          get "/account_data/:type", AccountController, :get_config, rl(:frequent_cheap)
          put "/account_data/:type", AccountController, :put_config, rl(:frequent_cheap)
          get "/rooms/:room_id/account_data/:type", AccountController, :get_config, rl(:frequent_cheap)
          put "/rooms/:room_id/account_data/:type", AccountController, :put_config, rl(:frequent_cheap)

          get "/rooms/:room_id/tags", AccountController, :get_tags, rl(:infrequent_bursts)
          put "/rooms/:room_id/tags/:tag", AccountController, :put_tag, rl(:infrequent_bursts)
          delete "/rooms/:room_id/tags/:tag", AccountController, :delete_tag, rl(:infrequent_bursts)
        end

        post "/join/:room_id_or_alias", RoomController, :join, rl(:infrequent_bursts)
        # TOIMPL:
        # post "/knock/:room_id_or_alias", RoomController, :knock
      end
    end
  end

  ### UNAUTHENTICATED CS-API ENDPOINTS ###
  scope "/_matrix" do
    pipe_through :cs_api

    scope "/client" do
      get "/versions", HomeserverInfoController, :versions, rl(:unauth_static_read)

      scope "/v1" do
        get "/auth_metadata", OAuth2Controller, :get_auth_metadata, rl(:unauth_static_read)
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
