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
      listeners: [Phoenix.CodeReloader],
      test_coverage: [
        ignore_modules: [
          RadioBeam.Application,
          RadioBeam.DataCase,
          RadioBeamWeb.Telemetry,
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
      mod: {RadioBeam.Application, []},
      extra_applications: [:logger, :runtime_tools]
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
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.2"},
      # {:memento, "~> 0.3.2"},
      memento(),
      {:argon2_elixir, "~> 4.0"},
      {:dotenv_parser, "~> 1.2", only: [:dev, :test]},
      polyjuice_util(),
      {:vix, "~> 0.30.0"},
      {:guardian, "~> 2.4"},
      {:gettext, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp memento do
    case System.get_env("MEMENTO_PATH", "use_fork") do
      "use_fork" ->
        {:memento, git: "https://github.com/Bentheburrito/memento.git", branch: "format-and-spec-corrections"}

      path ->
        {:memento, path: path}
    end
  end

  defp polyjuice_util do
    case System.get_env("POLYJUICE_PATH", "use_fork") do
      "use_fork" ->
        {:polyjuice_util,
         git: "https://gitlab.com/Bentheburrito/polyjuice_util.git", branch: "auth-checks-for-rooms-v6-thru-v11"}

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
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
      test: ["test"]
    ]
  end
end
