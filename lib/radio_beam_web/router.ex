defmodule RadioBeamWeb.Router do
  use RadioBeamWeb, :router

  alias RadioBeamWeb.{
    AccountController,
    AuthController,
    ClientController,
    ContentRepoController,
    FilterController,
    HomeserverInfoController,
    KeysController,
    LoginController,
    RelationsController,
    RoomController,
    SyncController
  }

  @cors %{
    "access-control-allow-origin" => "*",
    "access-control-allow-methods" => "GET, POST, PUT, DELETE, OPTIONS",
    "access-control-allow-headers" => "X-Requested-With, Content-Type, Authorization"
  }

  pipeline :spec do
    plug :accepts, ["json"]
    plug :put_secure_browser_headers, @cors
  end

  get "/", HomeserverInfoController, :home
  get "/.well-known/matrix/client", HomeserverInfoController, :well_known_client

  scope "/_matrix" do
    pipe_through :spec

    # these will be deprecated in the future
    scope "/media" do
      post "/v1/create", ContentRepoController, :create
      post "/v3/upload", ContentRepoController, :upload
      put "/v3/upload/:server_name/:media_id", ContentRepoController, :upload
    end

    scope "/client" do
      get "/versions", HomeserverInfoController, :versions

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
        get "/login", HomeserverInfoController, :login_types
        post "/login", LoginController, :login
        post "/register", AuthController, :register
        post "/refresh", AuthController, :refresh
        ### TOIMPL:
        # post "/logout/all", AuthController, :logout_all
        # post "/logout", AuthController, :logout

        # OPTIMPL: /login/get_token

        get "/sync", SyncController, :sync

        post "/createRoom", RoomController, :create
        get "/joined_rooms", RoomController, :joined

        put "/sendToDevice/:type/:transaction_id", ClientController, :send_to_device

        scope "/keys" do
          post "/upload", KeysController, :upload
          post "/device_signing/upload", KeysController, :upload_signing
          post "/claim", KeysController, :claim
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
        end

        scope "/account" do
          get "/whoami", AuthController, :whoami
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
