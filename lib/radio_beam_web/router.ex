defmodule RadioBeamWeb.Router do
  use RadioBeamWeb, :router

  alias RadioBeamWeb.{AuthController, HomeserverInfoController, LoginController, RoomController}

  pipeline :spec do
    plug :accepts, ["json"]
  end

  get "/", HomeserverInfoController, :home

  scope "/_matrix" do
    pipe_through :spec

    scope "/client" do
      get "/versions", HomeserverInfoController, :versions

      scope "/v3" do
        get "/capabilities", HomeserverInfoController, :capabilities
        get "/login", HomeserverInfoController, :login_types
        post "/login", LoginController, :login
        post "/register", AuthController, :register
        ### TOIMPL:
        # post "/refresh", AuthController, :refresh
        # post "/logout/all", AuthController, :logout_all
        # post "/logout", AuthController, :logout

        # OPTIMPL: /login/get_token

        post "/createRoom", RoomController, :create
        get "/joined_rooms", RoomController, :joined

        scope "/rooms" do
          post "/:room_id/invite", RoomController, :invite
        end
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
