defmodule Mix.Tasks.Fathom.Install do
  @shortdoc "Wires Fathom into the current project"

  @moduledoc """
  Sets up the surrounding project so that agents working in it find and use the
  program database.

      mix fathom.install

  It does three things:

    * writes the schema and a set of worked queries into `AGENTS.md`, between
      `<!-- fathom:begin -->` and `<!-- fathom:end -->` markers so re-running
      the task updates the section in place rather than appending a second copy
    * adds `.fathom/` to `.gitignore`, since the database is derived
    * tells you what to add to `mix.exs`, which it will not edit itself

  ## Options

    * `--guide` - path to the agent instructions file. Defaults to `AGENTS.md`,
      or `CLAUDE.md` if that exists and `AGENTS.md` does not.
    * `--database` - path the guide should point at. Defaults to
      `.fathom/program.db`.
  """

  use Mix.Task

  alias Fathom.Guide

  @default_db ".fathom/program.db"
  @switches [guide: :string, database: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)

    db = Keyword.get(opts, :database, @default_db)
    guide = Keyword.get_lazy(opts, :guide, &default_guide/0)

    write_guide(guide, db)
    update_gitignore()
    report_dep()
  end

  defp default_guide do
    if not File.exists?("AGENTS.md") and File.exists?("CLAUDE.md"),
      do: "CLAUDE.md",
      else: "AGENTS.md"
  end

  defp write_guide(path, db) do
    {begin_marker, end_marker} = Guide.markers()
    section = Guide.section(db)
    existing = if File.exists?(path), do: File.read!(path), else: ""

    {content, verb} =
      case String.split(existing, begin_marker, parts: 2) do
        [before, rest] ->
          after_section =
            case String.split(rest, end_marker, parts: 2) do
              [_inner, tail] -> tail
              [_only] -> ""
            end

          {before <> section <> String.trim_leading(after_section), "updated"}

        [_no_marker] ->
          separator = if existing == "" or String.ends_with?(existing, "\n\n"), do: "", else: "\n"
          {existing <> separator <> section, if(existing == "", do: "created", else: "updated")}
      end

    File.write!(path, content)
    Mix.shell().info([:green, "* #{verb} ", :reset, path])
  end

  defp update_gitignore do
    entry = ".fathom/"
    existing = if File.exists?(".gitignore"), do: File.read!(".gitignore"), else: ""

    if entry in String.split(existing, "\n", trim: true) do
      :ok
    else
      separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
      File.write!(".gitignore", existing <> separator <> entry <> "\n")
      Mix.shell().info([:green, "* updated ", :reset, ".gitignore"])
    end
  end

  defp report_dep do
    unless dep_present?() do
      Mix.shell().info("""

      Add Fathom to your dependencies, if it is not there already:

          {:fathom, "~> 0.1", only: [:dev], runtime: false}

      It has to be a dependency rather than an archive: the compiler loads the
      tracer from the code path while compiling your project, so the module
      must already be built by the time your own files compile. `runtime: false`
      keeps it out of releases.

      Then:

          mix deps.get
          mix fathom.build
      """)
    end
  end

  defp dep_present? do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> Enum.any?(&(elem(&1, 0) == :fathom))
  end
end
