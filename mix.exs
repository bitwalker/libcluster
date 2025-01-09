defmodule Cluster.Mixfile do
  use Mix.Project

  @version "3.5.0"
  @source_url "https://github.com/bitwalker/libcluster"

  def project do
    [
      app: :libcluster,
      version: @version,
      elixir: "~> 1.13",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      description: """
        Automatic Erlang cluster formation and management for Elixir/Erlang
        applications
      """,
      package: package(),
      docs: docs(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        flags: ~w(-Wunmatched_returns -Werror_handling -Wrace_conditions -Wno_opaque -Wunderspecs)
      ],
      preferred_cli_env: [
        vcr: :test,
        "vcr.delete": :test,
        "vcr.check": :test,
        "vcr.show": :test
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :jason, :crypto, :ssl]]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:exvcr, "~> 0.11", only: :test, runtime: false},
      {:jason, "~> 1.1"},
      {:telemetry, "~> 1.3"}
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE.md", "CHANGELOG.md"],
      maintainers: ["Paul Schoenfelder"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "https://hexdocs.pm/libcluster/changelog.html",
        GitHub: @source_url
      }
    ]
  end

  defp docs do
    [
      extras: ["CHANGELOG.md", "README.md"],
      main: "readme",
      source_url: @source_url,
      source_ref: @version,
      formatter_opts: [gfm: true]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
