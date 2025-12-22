defmodule RadioBeamWeb.Router do
  use RadioBeamWeb, :router

  import :timer, only: [minutes: 1, hours: 1]
  import RadioBeam.RateLimit, only: [new!: 4, /: 2]
  import RadioBeamWeb.Utils, only: [rl: 1]
  import Kernel, except: [/: 2]

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

  alias RadioBeamWeb.Plugs

  # Rate Limits
  @device_lifecycle new!(30 / minutes(5), 10 / hours(24), 2 / hours(24), 15 / minutes(15))
  @device_upkeep new!(80 / minutes(1), 10 / minutes(30), 5 / minutes(10), 80 / minutes(15))
  @exp_read_user_bursts new!(100 / minutes(1), 40 / minutes(3), 40 / minutes(2), 50 / minutes(5))
  @exp_write_user_bursts new!(50 / minutes(1), 15 / minutes(5), 15 / minutes(5), 30 / minutes(5))
  @frequent_ephemeral_write new!(500 / minutes(1), 50 / minutes(2), 25 / minutes(2), 50 / minutes(3))
  @infrequent_cheap_static_read new!(100 / minutes(1), 25 / minutes(2), 10 / minutes(2), 50 / minutes(2))
  @room_event_read new!(500 / minutes(1), 50 / minutes(1), 25 / minutes(1), 100 / minutes(2))
  @room_event_write new!(500 / minutes(1), 20 / minutes(1), 15 / minutes(1), 100 / minutes(2))
  # for endpoints likely to be hit by scrapers (e.g. root "/") that we don't care get rate limited aggressively
  @unauth_heavily_restrict_ip new!(30 / minutes(5), 1 / minutes(1), 1 / minutes(1), 5 / minutes(2))
  @unauth_static_read new!(200 / minutes(1), 1 / minutes(1), 1 / minutes(1), 100 / minutes(2))
  @user_metadata_read new!(500 / minutes(1), 100 / minutes(2), 50 / minutes(2), 100 / minutes(2))
  @user_metadata_write new!(100 / minutes(1), 20 / minutes(2), 15 / minutes(2), 50 / minutes(2))
  @user_sync new!(5_000 / minutes(1), 100 / minutes(1), 80 / minutes(1), 100 / minutes(1))

  if Mix.env() == :test do
    @absurdly_high_limit 2 ** 16
    @do_whatever_the_hell_you_want new!(
                                     @absurdly_high_limit / minutes(1),
                                     @absurdly_high_limit / minutes(1),
                                     @absurdly_high_limit / minutes(1),
                                     @absurdly_high_limit / minutes(1)
                                   )

    @device_lifecycle @do_whatever_the_hell_you_want
    @exp_write_user_bursts @do_whatever_the_hell_you_want
    @infrequent_cheap_static_read @do_whatever_the_hell_you_want
    @room_event_read @do_whatever_the_hell_you_want
    @room_event_write @do_whatever_the_hell_you_want
    @unauth_heavily_restrict_ip @do_whatever_the_hell_you_want
    @user_metadata_read @do_whatever_the_hell_you_want
    @user_metadata_write @do_whatever_the_hell_you_want
    @user_sync @do_whatever_the_hell_you_want
  end

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
    plug :put_secure_browser_headers
    plug Plugs.RateLimit
  end

  scope [] do
    pipe_through :cs_api

    get "/", HomeserverInfoController, :home, rl(@unauth_heavily_restrict_ip)
    get "/.well-known/matrix/client", HomeserverInfoController, :well_known_client, rl(@unauth_static_read)
  end

  scope "/oauth2" do
    pipe_through :cs_api

    post "/clients/register", OAuth2Controller, :register_client, rl(@device_lifecycle)

    post "/token", OAuth2Controller, :get_token, rl(@device_upkeep)
    post "/revoke", OAuth2Controller, :revoke_token, rl(@device_upkeep)
  end

  scope "/oauth2" do
    pipe_through :oauth2_authz_code_grant

    get "/auth", OAuth2Controller, :authenticate, rl(@device_lifecycle)
    post "/auth", OAuth2Controller, :authenticate, rl(@device_lifecycle)
  end

  ### LEGACY AUTH API - DEPRECATED ###
  scope "/_matrix" do
    pipe_through :cs_api

    scope "/client" do
      scope "/v3" do
        get "/login", HomeserverInfoController, :login_types, rl(@device_upkeep)
        post "/login", AuthController, :login, rl(@device_upkeep)
        post "/register", AuthController, :register, rl(@device_lifecycle)
        post "/refresh", AuthController, :refresh, rl(@device_upkeep)
      end
    end
  end

  ### AUTHENTICATED CS-API ENDPOINTS ###
  scope "/_matrix" do
    pipe_through :auth_cs_api

    # these will be deprecated in the future
    scope "/media" do
      post "/v1/create", ContentRepoController, :create, rl(@exp_write_user_bursts)
      post "/v3/upload", ContentRepoController, :upload, rl(@exp_write_user_bursts)

      put "/v3/upload/:server_name/:media_id", ContentRepoController, :upload, rl(@exp_write_user_bursts)
    end

    scope "/client" do
      scope "/v1" do
        scope "/media" do
          get "/config", ContentRepoController, :config, rl(@infrequent_cheap_static_read)
          get "/download/:server_name/:media_id/:filename", ContentRepoController, :download, rl(@exp_read_user_bursts)
          get "/download/:server_name/:media_id", ContentRepoController, :download, rl(@exp_read_user_bursts)
          get "/thumbnail/:server_name/:media_id", ContentRepoController, :thumbnail, rl(@exp_read_user_bursts)
        end

        scope "/rooms/:room_id/relations" do
          get "/:event_id", RelationsController, :get_children, rl(@room_event_read)
          get "/:event_id/:rel_type", RelationsController, :get_children, rl(@room_event_read)
          get "/:event_id/:rel_type/:event_type", RelationsController, :get_children, rl(@room_event_read)
        end
      end

      scope "/v3" do
        get "/capabilities", HomeserverInfoController, :capabilities, rl(@infrequent_cheap_static_read)

        get "/devices", ClientController, :get_device, rl(@user_metadata_read)
        get "/devices/:device_id", ClientController, :get_device, rl(@user_metadata_read)
        put "/devices/:device_id", ClientController, :put_device_display_name, rl(@user_metadata_write)

        get "/sync", SyncController, :sync, rl(@user_sync)

        post "/createRoom", RoomController, :create, rl(@exp_write_user_bursts)
        get "/joined_rooms", RoomController, :joined, rl(@user_metadata_read)

        put "/sendToDevice/:type/:transaction_id", ClientController, :send_to_device, rl(@user_metadata_write)

        scope "/keys" do
          get "/changes", KeysController, :changes, rl(@user_metadata_read)
          post "/claim", KeysController, :claim, rl(@user_metadata_write)
          post "/device_signing/upload", KeysController, :upload_cross_signing, rl(@user_metadata_write)
          post "/query", KeysController, :query, rl(@user_metadata_read)
          post "/signatures/upload", KeysController, :upload_signatures, rl(@user_metadata_write)
          post "/upload", KeysController, :upload, rl(@user_metadata_write)
        end

        scope "/room_keys" do
          get "/keys", RoomKeysController, :get_keys, rl(@user_metadata_read)
          get "/keys/:room_id", RoomKeysController, :get_keys, rl(@user_metadata_read)
          get "/keys/:room_id/:session_id", RoomKeysController, :get_keys, rl(@user_metadata_read)
          put "/keys", RoomKeysController, :put_keys, rl(@user_metadata_write)
          put "/keys/:room_id", RoomKeysController, :put_keys, rl(@user_metadata_write)
          put "/keys/:room_id/:session_id", RoomKeysController, :put_keys, rl(@user_metadata_write)
          delete "/keys", RoomKeysController, :delete_keys, rl(@user_metadata_write)
          delete "/keys/:room_id", RoomKeysController, :delete_keys, rl(@user_metadata_write)
          delete "/keys/:room_id/:session_id", RoomKeysController, :delete_keys, rl(@user_metadata_write)

          post "/version", RoomKeysController, :create_backup, rl(@user_metadata_write)
          get "/version", RoomKeysController, :get_backup_info, rl(@user_metadata_read)
          get "/version/:version", RoomKeysController, :get_backup_info, rl(@user_metadata_read)
          put "/version/:version", RoomKeysController, :put_backup_auth_data, rl(@user_metadata_write)
          delete "/version/:version", RoomKeysController, :delete_backup, rl(@user_metadata_write)
        end

        scope "/rooms" do
          post "/:room_id/invite", RoomController, :invite, rl(@room_event_write)
          post "/:room_id/join", RoomController, :join, rl(@room_event_write)
          post "/:room_id/leave", RoomController, :leave, rl(@room_event_write)
          # TOIMPL:
          # post "/:room_id/forget", RoomController, :forget
          # post "/:room_id/kick", RoomController, :kick
          # post "/:room_id/ban", RoomController, :ban
          # post "/:room_id/unban", RoomController, :unban

          put "/:room_id/send/:event_type", RoomController, :send, rl(@room_event_write)
          put "/:room_id/send/:event_type/:transaction_id", RoomController, :send, rl(@room_event_write)
          put "/:room_id/state/:event_type/:state_key", RoomController, :put_state, rl(@room_event_write)
          put "/:room_id/state/:event_type", RoomController, :put_state, rl(@room_event_write)

          put "/:room_id/redact/:event_id/:transaction_id", RoomController, :redact, rl(@room_event_write)

          get "/:room_id/event/:event_id", RoomController, :get_event, rl(@room_event_read)
          get "/:room_id/joined_members", RoomController, :get_joined_members, rl(@room_event_read)
          get "/:room_id/members", RoomController, :get_members, rl(@room_event_read)
          get "/:room_id/state", RoomController, :get_state, rl(@room_event_read)
          get "/:room_id/state/:event_type/:state_key", RoomController, :get_state_event, rl(@room_event_read)
          get "/:room_id/state/:event_type", RoomController, :get_state_event, rl(@room_event_read)
          get "/:room_id/messages", SyncController, :get_messages, rl(@room_event_read)
          get "/:room_id/timestamp_to_event", RoomController, :get_nearest_event, rl(@room_event_read)

          put "/:room_id/typing/:user_id", RoomController, :put_typing, rl(@frequent_ephemeral_write)
        end

        scope "/account" do
          get "/whoami", OAuth2Controller, :whoami, rl(@user_metadata_read)
        end

        scope "/user/:user_id" do
          post "/filter", FilterController, :put, rl(@user_metadata_write)
          get "/filter/:filter_id", FilterController, :get, rl(@user_metadata_read)

          get "/account_data/:type", AccountController, :get_config, rl(@user_metadata_read)
          put "/account_data/:type", AccountController, :put_config, rl(@user_metadata_read)
          get "/rooms/:room_id/account_data/:type", AccountController, :get_config, rl(@user_metadata_read)
          put "/rooms/:room_id/account_data/:type", AccountController, :put_config, rl(@user_metadata_read)
        end

        post "/join/:room_id_or_alias", RoomController, :join, rl(@room_event_write)
        # TOIMPL:
        # post "/knock/:room_id_or_alias", RoomController, :knock
      end
    end
  end

  ### UNAUTHENTICATED CS-API ENDPOINTS ###
  scope "/_matrix" do
    pipe_through :cs_api

    scope "/client" do
      get "/versions", HomeserverInfoController, :versions, rl(@unauth_static_read)

      scope "/v1" do
        get "/auth_metadata", OAuth2Controller, :get_auth_metadata, rl(@unauth_static_read)
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
