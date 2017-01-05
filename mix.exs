defmodule Cluster.Mixfile do
  use Mix.Project

  def project do
    [app: :libcluster,
     version: "2.0.3",
     elixir: "~> 1.3",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     description: "Automatic Erlang cluster formation and management for Elixir/Erlang applications",
     package: package(),
     docs: docs(),
     deps: deps(),
     dialyzer: [
        flags: ~w(-Wunmatched_returns -Werror_handling -Wrace_conditions -Wno_opaque -Wunderspecs)
     ]]
  end

  def application do
    [applications: [:logger, :inets, :poison],
     mod: {Cluster.App, []}]
  end

  defp deps do
    [{:ex_doc, "~> 0.13", only: :dev},
     {:dialyxir, "~> 0.3", only: :dev},
     {:poison, "~> 3.0"}]
  end

  defp package do
    [files: ["lib", "mix.exs", "README.md", "LICENSE.md"],
     maintainers: ["Paul Schoenfelder"],
     licenses: ["MIT"],
     links: %{ "GitHub": "https://github.com/bitwalker/libcluster" }]
  end

  defp docs do
    [main: "readme",
     formatter_opts: [gfm: true],
     extras: [
       "README.md"
     ]]
  end

end
