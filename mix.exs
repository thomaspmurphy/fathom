defmodule Fathom.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/thomaspmurphy/fathom"

  def project do
    [
      app: :fathom,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "A program database for Elixir codebases. Compiles your project with a tracer " <>
          "and dumps symbols, call graphs and framework facts into SQLite for agents to query.",
      package: package(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:exqlite, "~> 0.27"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [main: "readme", source_url: @source_url, extras: ["README.md"]]
  end

  # Everything that has to pass before a change lands. Credo runs ExSlop's
  # checks as a plugin; see `.credo.exs`.
  defp aliases do
    [quality: ["format --check-formatted", "credo --strict", "ex_dna", "dialyzer"]]
  end

  # The PLT is keyed on the toolchain, and Fathom is already sensitive to which
  # OTP built it, so keep it out of the shared build directory.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      # Mix is not in the default PLT, and this project is mostly Mix tasks;
      # without it every `Mix.shell/0` reads as a call to a function that does
      # not exist.
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :underspecs, :unmatched_returns]
    ]
  end
end
