# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

### STATIC CONFIG / SUPPORTED FUNCTIONS ###
config :radio_beam,
  # ecto_repos: [RadioBeam.Repo],
  access_token_lifetime: :timer.hours(72),
  env: config_env(),
  capabilities: %{
    "m.change_password": %{enabled: false},
    "m.room_versions": %{
      available: Map.new(3..11, &{"#{&1}", "stable"}),
      default: "11"
    },
    "m.set_displayname": %{enabled: false},
    "m.set_avatar_url": %{enabled: false},
    "m.3pid_changes": %{enabled: false}
  },
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  # TOIMPL: m.login.token
  login_types: %{flows: [%{type: "m.login.password"}]},
  max_events: [timeline: 200, state: 100],
  registration_enabled: true,
  versions: %{unstable_features: %{}, versions: ["v1.8", "v1.9", "v1.10", "v1.11"]}

config :radio_beam, RadioBeam.ContentRepo,
  allowed_mimes:
    ~w|image/jpg image/png image/gif audio/mpeg audio/wav audio/aac video/mp4 text/csv application/octet-stream|,
  dir: :default,
  # By default, a single file may not exceed 8MB
  single_file_max_bytes: 8_000_000,
  # By default, only cache 200MB of remote media
  remote_media: %{max_bytes: 200_000_000},
  # "The recommended default expiration is 24 hours which should be enough time
  # to accommodate users on poor connection who find a better connection to
  # complete the upload"
  unused_mxc_uris_expire_in_ms: :timer.hours(24),
  # By default, each user can only upload a total of 50MB or 50 files 
  # (whichever limit is reached first)
  users: %{max_bytes: 50_000_000, max_files: 50, max_pending: 5}

# Configures the endpoint
config :radio_beam, RadioBeamWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: RadioBeamWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: RadioBeam.PubSub,
  live_view: [signing_salt: "DWuIC2o8"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :radio_beam, RadioBeam.Mailer, adapter: Swoosh.Adapters.Local

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Mnesia database location
config :mnesia,
  dir: ~c".mnesia/#{Mix.env()}/#{node()}"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
