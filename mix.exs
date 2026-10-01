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
      elixirc_paths: elixirc_paths(Mix.env())
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [main: "readme", source_url: @source_url, extras: ["README.md"]]
  end
end
