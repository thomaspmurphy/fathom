# Compares answering real code-navigation questions with Fathom against doing
# it with ripgrep, which is what an agent reaches for otherwise.
#
#     elixir bench/compare.exs <repo> <program.db> [scenarios.exs]
#
# The questions live in a separate file because they have to name real modules
# in the repository under test. `bench/scenarios/credo.exs` is the committed
# set, written against an open source project so the numbers in the README can
# be reproduced; point the third argument at your own file to run it somewhere
# else.
#
# Both sides run for real, against the same checkout, and everything reported
# is measured rather than estimated:
#
#   round trips  tool calls needed. An agent pays latency and a model turn for
#                each one, so this usually matters more than milliseconds.
#   bytes        total output the agent has to read. A proxy for tokens.
#   ms           wall time.
#
# Where grep cannot answer a question at all, that is recorded as such rather
# than replaced with a command that answers an easier question. Where grep
# wins, that is recorded too.

defmodule Compare do
  @moduledoc false

  @default_scenarios "bench/scenarios/credo.exs"

  def main([repo_path, db_path | rest]) do
    Process.put(:repo, Path.expand(repo_path))
    Process.put(:db, Path.expand(db_path))

    scenarios_path = List.first(rest) || @default_scenarios
    {scenarios, _bindings} = Code.eval_file(scenarios_path)

    results = scenarios |> Enum.map(&run/1) |> Enum.reject(&skip?/1)

    report(scenarios_path, results)
    summary(results)
  end

  def main(_) do
    IO.puts("usage: elixir bench/compare.exs <repo> <program.db> [scenarios.exs]")
  end

  defp repo, do: Process.get(:repo)
  defp db, do: Process.get(:db)

  # -- running ---------------------------------------------------------------

  defp run(scenario) do
    fathom = measure([{:sqlite, scenario.sql}])
    grep = measure(Enum.map(scenario.grep, &{:shell, &1}))

    Map.merge(scenario, %{fathom: fathom, grep: grep})
  end

  # A scenario marked `requires:` depends on facts a given project may not have
  # — routes need a Phoenix router, schemas need Ecto. Reporting those as a win
  # over an empty table would be dishonest, so they drop out instead.
  defp skip?(%{requires: table}) do
    case exec({:sqlite, "SELECT count(*) FROM #{table}"}) do
      "0\n" -> true
      _ -> false
    end
  end

  defp skip?(_scenario), do: false

  # Each command is timed and its output measured. Warm the page cache first so
  # this measures the tools rather than the filesystem.
  defp measure([]), do: %{ms: 0, bytes: 0, trips: 0, rows: 0}

  defp measure(commands) do
    Enum.each(commands, &exec/1)

    results = Enum.map(commands, fn command -> :timer.tc(fn -> exec(command) end) end)

    %{
      ms: results |> Enum.map(&elem(&1, 0)) |> Enum.sum() |> div(1000),
      bytes: results |> Enum.map(&byte_size(elem(&1, 1))) |> Enum.sum(),
      trips: length(commands),
      rows: results |> Enum.map(&lines(elem(&1, 1))) |> Enum.sum()
    }
  end

  defp exec({:sqlite, sql}) do
    {out, _status} =
      System.cmd("sqlite3", ["-readonly", "-noheader", "-separator", "\t", db(), sql],
        stderr_to_stdout: true
      )

    out
  end

  defp exec({:shell, command}) do
    {out, _status} = System.cmd("sh", ["-c", command], cd: repo(), stderr_to_stdout: true)
    out
  end

  defp lines(""), do: 0
  defp lines(output), do: output |> String.split("\n", trim: true) |> length()

  # -- reporting -------------------------------------------------------------

  defp report(scenarios_path, results) do
    IO.puts("\n# Fathom vs ripgrep\n")
    IO.puts("Repository: #{repo()}")
    IO.puts("Database:   #{db()}")
    IO.puts("Scenarios:  #{scenarios_path}\n")

    for r <- results do
      IO.puts("## #{r.question}\n")

      IO.puts(
        "| | round trips | output bytes | ms | rows |\n" <>
          "|---|---|---|---|---|\n" <>
          row("fathom", r.fathom) <>
          row("ripgrep (#{r.grep_verdict})", r.grep)
      )

      IO.puts("\n#{r.note}\n")
    end
  end

  defp row(label, %{trips: 0}), do: "| #{label} | — | — | — | cannot answer |\n"
  defp row(label, m), do: "| #{label} | #{m.trips} | #{m.bytes} | #{m.ms} | #{m.rows} |\n"

  defp summary(results) do
    # Both sides are totalled over the same questions. Including Fathom's cost
    # on questions grep cannot attempt would compare the two over different
    # work and flatter neither honestly.
    answerable = Enum.reject(results, &(&1.grep_verdict == :impossible))
    total = fn rows, side, field -> rows |> Enum.map(&get_in(&1, [side, field])) |> Enum.sum() end

    fathom_bytes = total.(answerable, :fathom, :bytes)
    grep_bytes = total.(answerable, :grep, :bytes)
    count = fn verdict -> Enum.count(results, &(&1.grep_verdict == verdict)) end

    IO.puts("""
    ## Totals

    Over #{length(results)} questions, grep answers #{count.(:correct)} correctly, \
    #{count.(:approximate)} approximately, #{count.(:wrong)} wrongly, and cannot \
    attempt #{count.(:impossible)} at all.

    Totalled over the #{length(answerable)} questions grep can attempt:

    | | round trips | output bytes | ms |
    |---|---|---|---|
    | fathom | #{total.(answerable, :fathom, :trips)} | #{fathom_bytes} | \
    #{total.(answerable, :fathom, :ms)} |
    | ripgrep | #{total.(answerable, :grep, :trips)} | #{grep_bytes} | \
    #{total.(answerable, :grep, :ms)} |

    #{ratio(fathom_bytes, grep_bytes)}

    Two things this does not capture. Grep needs no index, which is a real \
    advantage on a repository you have just cloned and will ask two questions \
    about; one `mix fathom.build` has to be amortised against that. And the \
    round-trip counts above assume the agent writes the right grep first time, \
    which in practice it often does not.
    """)
  end

  defp ratio(fathom, grep) when fathom > 0 and grep > 0 do
    larger = max(fathom, grep) / min(fathom, grep)

    cond do
      larger < 1.2 ->
        "Output volume is about the same. The difference is not how much the " <>
          "agent reads but what it gets: Fathom returns the answer, grep returns " <>
          "a list of matches that still has to be read and interpreted."

      grep > fathom ->
        "Fathom returns #{Float.round(larger, 1)}x less output to read."

      true ->
        "Fathom returns #{Float.round(larger, 1)}x more output, because it answers " <>
          "completely where grep returns a partial match list."
    end
  end

  defp ratio(_fathom, _grep), do: ""
end

Compare.main(System.argv())
