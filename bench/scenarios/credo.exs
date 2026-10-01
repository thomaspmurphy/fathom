# Benchmark questions written against Credo, so the numbers in the README can
# be reproduced from a public codebase.
#
#     git clone https://github.com/rrrene/credo
#     cd credo && mix deps.get && mix fathom.build
#     elixir bench/compare.exs ../credo ../credo/.fathom/program.db
#
# Each scenario is one question, with the SQL Fathom answers it in and the
# sequence of ripgrep calls an agent would realistically run instead.
#
#   :correct      grep gets the right answer
#   :approximate  grep gets something usable but imprecise
#   :wrong        grep's answer is missing results or is not the question asked
#   :impossible   no sequence of greps produces this
#
# A scenario with `requires:` is skipped when that table is empty, so the
# framework questions simply drop out on a project with no Phoenix or Ecto
# rather than counting as a win over nothing.

[
  %{
    question: "Where is Credo.Code.Name.full/1 defined?",
    sql: "SELECT mfa, file, line FROM functions WHERE mfa = 'Credo.Code.Name.full/1'",
    grep: [
      ~S{rg -n --type elixir "defmodule Credo.Code.Name do" lib},
      ~S{rg -n --type elixir "def full\(" lib/credo/code/name.ex}
    ],
    grep_verdict: :correct,
    note: "Grep is fine here, and needs two steps only because the first locates the file."
  },
  %{
    question: "Where is Credo.Service.SourceFileAST.get/1 defined?",
    sql: "SELECT mfa, file, line FROM functions WHERE mfa = 'Credo.Service.SourceFileAST.get/1'",
    grep: [~S{rg -n --type elixir "def get\(" lib}],
    grep_verdict: :wrong,
    note:
      "That module's entire body is `use Credo.Service.ETSTableHelper`, so `get/1` exists " <>
        "only after macro expansion. Grep returns `def get(` from five unrelated modules " <>
        "and the one inside the macro's `quote` block, which does not say who received it."
  },
  %{
    question: "Which functions call Credo.Code.Block.do_block_for!/1?",
    sql: """
    SELECT caller, file, line FROM calls
    WHERE callee = 'Credo.Code.Block.do_block_for!/1' ORDER BY caller
    """,
    grep: [~S{rg -n --type elixir "do_block_for!\(" lib}],
    grep_verdict: :approximate,
    note:
      "Grep finds the call sites but not which function encloses them, which is what " <>
        "was asked. The agent has to open each file to find out."
  },
  %{
    question: "Which public functions eventually reach Credo.Code.Block.do_block_for!/1?",
    sql: """
    WITH RECURSIVE up(mfa) AS (
      SELECT caller FROM calls WHERE callee = 'Credo.Code.Block.do_block_for!/1'
      UNION
      SELECT c.caller FROM calls c JOIN up ON c.callee = up.mfa
    )
    SELECT f.mfa, f.file, f.line FROM functions f JOIN up USING (mfa)
    WHERE f.kind = 'def' ORDER BY f.mfa
    """,
    # A transitive closure is not expressible as a grep. The agent greps, reads
    # the enclosing function names out of the results, greps for those, and
    # repeats. Three rounds is generous and still incomplete: there are nine
    # direct callers and sixty-eight public functions that actually reach it.
    grep: [
      ~S{rg -n --type elixir -B4 "do_block_for!\(" lib},
      ~S{rg -n --type elixir "do_block_for\(|first_param_for\(|calls_in_body\(" lib},
      ~S{rg -n --type elixir "run_on_source_file\(|traverse\(" lib}
    ],
    grep_verdict: :wrong,
    note:
      "Every round needs the agent to read enclosing function names out of the previous " <>
        "round's output and guess the next pattern. Paths through private functions and " <>
        "through pipelines are the ones it loses."
  },
  %{
    question: "Which modules implement the Credo.Check behaviour?",
    sql: "SELECT module FROM behaviours WHERE behaviour = 'Credo.Check' ORDER BY module",
    grep: [
      ~S{rg -l --type elixir "@behaviour Credo.Check" lib},
      ~S{rg -l --type elixir "use Credo.Check" lib}
    ],
    grep_verdict: :approximate,
    note:
      "The explicit form appears in two files; the behaviour is actually set by `use` in " <>
        "a hundred and thirty. Grep gets close, but only if you already know which idiom " <>
        "this library uses, and `use Credo.Check` also appears in files that are not checks."
  },
  %{
    question:
      "Which modules does Credo.CLI.Command.Suggest.SuggestCommand depend on at compile time?",
    sql: """
    SELECT to_module, type FROM module_deps
    WHERE from_module = 'Credo.CLI.Command.Suggest.SuggestCommand' AND type = 'compile'
    ORDER BY to_module
    """,
    grep: [
      ~S{rg -n --type elixir "alias |import |use " lib/credo/cli/command/suggest/suggest_command.ex}
    ],
    grep_verdict: :wrong,
    note:
      "Whether a reference is a compile-time dependency is a property of where it is used, " <>
        "not of how it is written. The text of an `alias` says nothing either way, and " <>
        "compile-time dependencies are what make a recompile cascade."
  },
  %{
    question: "Does any check reach the terminal output module directly?",
    sql: """
    SELECT caller, file, line FROM calls
    WHERE caller_module LIKE 'Credo.Check.%' AND callee_module = 'Credo.CLI.Output.UI'
    ORDER BY caller
    """,
    grep: [~S{rg -n --type elixir "Output.UI\." lib/credo/check}],
    grep_verdict: :approximate,
    note:
      "This is the shape an architecture rule takes: a query that should return no rows. " <>
        "Grep matches the text anywhere, including comments, docs and strings, and still " <>
        "cannot name the function the violation is in."
  },
  %{
    question: "Which public functions are never called from anywhere in this project?",
    sql: """
    SELECT f.mfa, f.file, f.line FROM functions f
    LEFT JOIN calls c ON c.callee = f.mfa
    WHERE f.kind = 'def' AND c.callee IS NULL AND f.generated = 0
      AND NOT EXISTS (
        SELECT 1 FROM callbacks cb JOIN behaviours b ON b.behaviour = cb.module
        WHERE b.module = f.module AND cb.name = f.name AND cb.arity = f.arity
      )
    ORDER BY f.mfa LIMIT 50
    """,
    grep: [],
    grep_verdict: :impossible,
    note:
      "Requires the complement of the call graph. The exclusions drop macro-generated " <>
        "functions and behaviour callbacks invoked by the library that declared them; " <>
        "without the first, `use` statements alone contribute thousands of false hits."
  },
  %{
    question: "Where does this codebase dispatch dynamically, so the call graph is incomplete?",
    sql: "SELECT caller, kind, file, line FROM dynamic_sites ORDER BY caller",
    grep: [
      ~S{rg -n --type elixir "apply\(" lib},
      ~S{rg -n --type elixir "Code.eval" lib}
    ],
    grep_verdict: :wrong,
    note:
      "Grep finds `apply/3`. It cannot find `mod.run(arg)` where `mod` is a variable, " <>
        "because that is textually identical to any other call. Sixty-eight of these " <>
        "sites are of that kind."
  },
  %{
    question: "Which HTTP endpoints eventually touch a given table?",
    requires: :routes,
    sql: """
    WITH RECURSIVE reach(verb, path, mfa) AS (
      SELECT r.verb, r.path, r.plug || '.' || r.action || '/2' FROM routes r
      UNION
      SELECT re.verb, re.path, c.callee FROM calls c JOIN reach re ON c.caller = re.mfa
    )
    SELECT DISTINCT re.verb, re.path FROM reach re
    JOIN struct_uses su ON su.caller = re.mfa
    JOIN schemas s ON s.module = su.struct_module
    WHERE s.source IS NOT NULL ORDER BY re.path
    """,
    grep: [],
    grep_verdict: :impossible,
    note:
      "Needs the router, the call graph and Ecto's table mapping joined together. " <>
        "Skipped on a project with no Phoenix router."
  }
]
