defmodule RadioBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :radio_beam,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # compilers: [:phoenix_live_view] ++ Mix.compilers(),
      compilers: [:boundary] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      boundary: [
        default: [
          check: [
            aliases: true,
            apps: [:argon2_elixir, :ecto, :guardian, :hammer, :polyjuice_util, :phoenix, {:mix, :runtime}]
          ]
        ]
      ],
      test_coverage: [
        ignore_modules: [
          RadioBeamApplication,
          RadioBeam.DataCase,
          RadioBeam.User.Authentication.OAuth2.Builtin.Guardian.Plug,
          RadioBeamWeb.Telemetry,
          RadioBeamWeb.CoreComponents,
          RadioBeamWeb.Gettext,
          RadioBeamWeb.Layouts,
          RadioBeamWeb.OAuth2HTML,
          Fixtures,
          # to remove later
          RadioBeamWeb.Plugs.UserInteractiveAuth
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {RadioBeamApplication, []},
      extra_applications: [:logger, :runtime_tools, :os_mon, :mnesia]
    ]
  end

  def cli do
    [
      preferred_envs: [lint: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},

      # {:phoenix_ecto, "~> 4.4"},
      {:ecto_sql, "~> 3.10"},
      # {:postgrex, ">= 0.0.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons", tag: "v2.2.0", sparse: "optimized", app: false, compile: false, depth: 1},
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.2"},
      {:argon2_elixir, "~> 4.0"},
      {:dotenv_parser, "~> 1.2", only: [:dev, :test]},
      polyjuice_util(),
      {:vix, "~> 0.30.0"},
      {:guardian, "~> 2.4"},
      {:gettext, "~> 1.0"},
      {:hammer, "~> 7.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10", runtime: false}
    ]
  end

  defp polyjuice_util do
    case System.get_env("POLYJUICE_PATH", "use_fork") do
      "use_fork" ->
        {:polyjuice_util, git: "https://gitlab.com/Bentheburrito/polyjuice_util.git", branch: "room-event-protocol"}

      path ->
        {:polyjuice_util, path: path}
    end
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      # setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      setup: ["deps.get", "assets.setup", "assets.build"],
      # "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      # "ecto.reset": ["ecto.drop", "ecto.setup"],
      # test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
      test: ["test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind radio_beam", "esbuild radio_beam"],
      "assets.deploy": [
        "tailwind radio_beam --minify",
        "esbuild radio_beam --minify",
        "phx.digest"
      ],
      lint: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "credo",
        "format --check-formatted",
        # "cmd --shell './bin/xref_check.sh'",
        "cmd --shell 'mix xref graph --format cycles --fail-above 3 > /dev/null'",
        "test"
      ]
    ]
  end
end
