defmodule Mix.Tasks.Fathom.Build do
  @shortdoc "Compiles the project with a tracer and writes a program database"

  @moduledoc """
  Builds the program database for the current project.

      mix fathom.build

  The task compiles the project from scratch with `Fathom.Tracer` attached,
  reflects over the resulting modules, and writes everything to
  `.fathom/program.db`.

  ## Options

    * `--output`, `-o` - where to write the database. Defaults to
      `.fathom/program.db`.
    * `--no-compile` - reuse the facts from an already-running build. Only
      useful when embedding this task in a larger pipeline.
    * `--quiet` - suppress the summary.

  ## Why it recompiles everything

  The tracer only sees what the compiler actually compiles. A warm build would
  produce a database covering whichever files happened to be stale, so the
  default is a full `--force` compile into a separate build directory
  (`_build/$MIX_ENV-fathom`) that leaves your normal build artefacts alone.
  """

  use Mix.Task

  alias Fathom.{Facts, Introspect, Store}

  @default_output ".fathom/program.db"

  @switches [output: :string, compile: :boolean, quiet: :boolean]
  @aliases [o: :output]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    output = Keyword.get(opts, :output, @default_output)
    root = File.cwd!()
    started = System.monotonic_time(:millisecond)

    Facts.init()

    if Keyword.get(opts, :compile, true), do: compile!()

    modules = Introspect.project_modules()
    Introspect.run(modules)

    meta = %{
      project: Mix.Project.config()[:app],
      mix_env: Mix.env(),
      module_count: length(modules),
      source_root: root
    }

    {:ok, counts} = Store.write(output, root, meta)
    Facts.destroy()

    elapsed = System.monotonic_time(:millisecond) - started
    unless opts[:quiet], do: report(output, counts, elapsed)
    warn_if_untraced(counts)

    :ok
  end

  # Introspection reads compiled artefacts and so succeeds whether or not the
  # tracer ever ran, which makes a tracer that did not fire look like a smaller
  # but valid database. Definitions only come from the tracer, so their absence
  # is the signal.
  defp warn_if_untraced(counts) do
    if Map.get(counts, :functions, 0) == 0 do
      Mix.shell().error("""
      No definitions were recorded, so this database has no call graph.

      The tracer only observes files the compiler actually compiles. This
      usually means compilation was skipped because something else in the same
      `mix` invocation had already compiled the project. Run `mix fathom.build`
      on its own.
      """)
    end
  end

  # A traced build has to be a full build: the tracer only sees what the
  # compiler actually compiles, so a warm build would produce a database
  # covering whichever files happened to be stale. `--force` rebuilds the
  # project's own files, which leaves the build directory just as warm as it
  # found it; dependencies are untouched.
  #
  # Set MIX_BUILD_PATH in the environment if you would rather this never
  # touched your main build at all. It has to come from outside the process,
  # since by the time this task runs Mix has already resolved its paths.
  #
  # `--no-prune-code-paths` matters when Fathom is not a declared dependency of
  # the project — running it through `ERL_LIBS`, say. Mix prunes the code path
  # to the applications the project declares, which would drop the tracer
  # before the compiler could load it.
  # `Mix.Task.rerun/2` only re-enables the task it is given. If anything has
  # already run `compile` in this session — `mix do compile + fathom.build`, or
  # any task that depends on compilation — the sub-tasks underneath it are
  # still marked as run and the forced build silently does nothing, leaving a
  # database with introspection facts and no call graph. Re-enable the whole
  # chain first.
  @compilers ~w(compile compile.all compile.elixir compile.app compile.protocols)

  # Every module the tracer reaches has to be loaded before compilation starts,
  # not just the tracer itself. Pruning removes paths but not already-loaded
  # modules, so anything still waiting to be loaded lazily — `Fathom.Dynamic`
  # is only called the first time a definition is scanned — becomes
  # unreachable mid-compile and takes the build down with it.
  @tracer_modules [Fathom.Tracer, Fathom.Dynamic, Fathom.Facts]

  defp compile! do
    Enum.each(@tracer_modules, &Code.ensure_loaded!/1)
    Enum.each(@compilers, &Mix.Task.reenable/1)

    Mix.Task.run("compile", [
      "--force",
      "--no-prune-code-paths",
      "--tracer",
      "Fathom.Tracer"
    ])
  end

  defp report(output, counts, elapsed) do
    total = counts |> Map.values() |> Enum.sum()
    size = output |> File.stat!() |> Map.fetch!(:size)

    Mix.shell().info([
      :green,
      "* fathom ",
      :reset,
      "#{output} — #{format_number(total)} facts, #{format_bytes(size)}, #{elapsed}ms"
    ])

    counts
    |> Enum.sort_by(fn {_table, count} -> -count end)
    |> Enum.each(fn {table, count} ->
      Mix.shell().info("    #{String.pad_trailing(to_string(table), 16)} #{format_number(count)}")
    end)
  end

  defp format_number(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{div(bytes, 1024)}KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)}MB"
end
