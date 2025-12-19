import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# config :radio_beam, RadioBeam.Repo,
#   username: "postgres",
#   password: "postgres",
#   hostname: "localhost",
#   database: "radio_beam_test#{System.get_env("MIX_TEST_PARTITION")}",
#   pool: Ecto.Adapters.SQL.Sandbox,
#   pool_size: System.schedulers_online() * 2

config :radio_beam,
  access_token_lifetime: {2, :second},
  server_name: "localhost",
  admins: ["@admin:localhost"]

config :radio_beam, RadioBeam.ContentRepo,
  allowed_mimes:
    ~w|image/jpg image/png image/gif audio/mpeg audio/wav audio/aac video/mp4 text/csv application/octet-stream|,
  dir: :default,
  max_wait_for_download_ms: :timer.seconds(1),
  single_file_max_bytes: 24_000,
  remote_media: %{max_bytes: 2_000},
  unused_mxc_uris_expire_in_ms: :timer.seconds(5),
  users: %{max_bytes: 30_000, max_files: 5, max_reserved: 5}

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :radio_beam, RadioBeamWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "aZ7hZ7AitaNtfK2II6u+xR7DcuApYg4xxdNfETN9YhJcxfwbUEL+PLuaNyjiC+k1",
  server: false

# In test we don't send emails.
config :radio_beam, RadioBeam.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
