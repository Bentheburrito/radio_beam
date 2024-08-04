# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :radio_beam,
  # ecto_repos: [RadioBeam.Repo],
  access_token_lifetime: :timer.hours(72),
  env: config_env(),
  capabilities: %{
    "m.change_password": %{enabled: false},
    "m.room_versions": %{available: %{"5" => "stable", "4" => "stable"}, default: "5"},
    "m.set_displayname": %{enabled: false},
    "m.set_avatar_url": %{enabled: false},
    "m.3pid_changes": %{enabled: false}
  },
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  ### STATIC CONFIG / SUPPORTED FUNCTIONS ###
  # TOIMPL: m.login.token
  login_types: %{flows: [%{type: "m.login.password"}]},
  max_events: [timeline: 400, state: 200],
  registration_enabled: true,
  versions: %{unstable_versions: %{}, versions: ["v1.9"]}

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
