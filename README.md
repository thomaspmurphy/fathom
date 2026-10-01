# Fathom

A program database for Elixir codebases.

Fathom compiles your project under a compiler tracer and writes what the
compiler resolved into a SQLite file: every definition, every call, module
dependencies and their kind, Ecto schemas, Phoenix routes, behaviours,
protocols, and the places where dispatch is dynamic enough that the call graph
stops being complete.

Then an agent can ask the questions it actually has, in SQL:

```sql
WITH RECURSIVE up(mfa) AS (
  SELECT caller FROM calls WHERE callee = 'MyApp.Repo.delete_all/1'
  UNION
  SELECT c.caller FROM calls c JOIN up ON c.callee = up.mfa
)
SELECT f.mfa, f.file, f.line
FROM functions f JOIN up USING (mfa)
WHERE f.kind = 'def';
```

Which public functions can delete everything? That question has no grep, and no
LSP request either. "Find references" gives you one hop, and you walk the rest
by hand.

## Why not an LSP

This follows a suggestion from [José Valim][post]. The Language Server Protocol
was built for editors, so its operations are addressed by file, line and column,
coordinates an agent does not track and has to go and find before it can ask
anything. It also answers one hop at a time, because that is how a human reads
code: jump to definition, look around, jump again.

An agent has neither constraint. It will happily write a query, and it can
compose questions no IDE would ever put in a menu. The information a language
server already has is better exposed as a database than as a protocol.

[post]: https://dashbit.co/blog/program-databases-over-lsps

## Install

Add Fathom as a development dependency:

```elixir
def deps do
  [{:fathom, "~> 0.1", only: [:dev], runtime: false}]
end
```

```
mix deps.get
mix fathom.install   # writes the schema and example queries into AGENTS.md
mix fathom.build     # compiles under the tracer, writes .fathom/program.db
```

It has to be a dependency rather than an archive or an escript. The compiler
loads the tracer from the code path while compiling your files, so it must
already be built, and built by the same toolchain: BEAM files from OTP 28 will
not load on OTP 27.

If you would rather not touch `mix.exs`, you can put a build of Fathom on the
code path from outside, as long as it was compiled with the same Elixir and OTP
as the target project:

```
ERL_LIBS=/path/to/fathom/_build/dev/lib mix fathom.build
```

## Use

```
mix fathom.build                     # rebuild after changing code
mix fathom.query "SELECT ..."        # query without needing sqlite3
sqlite3 .fathom/program.db "SELECT ..."
```

`mix fathom.install` writes the schema and a set of worked queries into
`AGENTS.md`, between markers so re-running it updates in place. That file is
what makes an agent use the database instead of falling back to grep.

## What is in it

```
modules          functions        calls            module_deps
struct_uses      alias_refs       use_sites        compile_envs
behaviours       callbacks        types            impls
schemas          schema_fields    schema_assocs    routes
dynamic_sites    meta
```

`mfa` columns are strings like `"MyApp.Accounts.create_user/2"` and join
everything together. The schema is denormalised on purpose: every row that
refers to a function also carries its module, so most questions need no join.

Facts come from three places. A [compiler tracer][tracers] records references
after macro expansion, which is the only way to see what `use`, `import` and
framework macros actually generated. While each module is still open,
`Module.definitions_in/1` yields every definition including private ones, which
cannot be recovered from the BEAM file afterwards. After compilation,
reflection fills in docs, specs, behaviours, and whatever Ecto and Phoenix will
tell you about themselves.

[tracers]: https://hexdocs.pm/elixir/Code.html#module-compilation-tracers

### Two things worth knowing

**Macro-generated definitions are marked.** Running this over Credo, 3,016 of
its 4,701 function definitions came from a macro rather than from someone
typing them. `Credo.Service.SourceFileAST` is a four-line module whose entire
body is `use Credo.Service.ETSTableHelper`, and `use Ecto.Repo` contributes
about seventy public functions to any project that has one. They are flagged
with `generated = 1`, because otherwise they swamp any question about the code
a person actually wrote.

**Gaps in the call graph are recorded, not hidden.** `apply/3`, a module held in
a variable or read from config, a protocol dispatch. None of these produce an
edge, and some produce no trace event at all. Fathom finds them by walking the
expanded AST and records them in `dynamic_sites`. An agent asking "who calls
this?" can also ask "does this module dispatch dynamically?" and know how far to
trust the answer. That is more useful than a graph that claims to be total.

Beyond that: the database covers your project and not its dependencies, and it
is built from one `MIX_ENV`, so a `dev` build does not see test code.

## Does it beat grep?

`bench/compare.exs` runs real navigation questions against both, on the same
checkout, measuring round trips, output size and wall time. The questions live
in a separate file because they have to name real modules; the committed set is
written against [Credo][credo] so the numbers below can be reproduced.

```
git clone https://github.com/rrrene/credo && cd credo
mix deps.get && mix fathom.build
elixir path/to/fathom/bench/compare.exs . .fathom/program.db
```

Of nine questions, grep answered one correctly, three approximately, four
wrongly, and could not attempt one at all. Across the eight it could attempt,
Fathom needed **8 tool calls against 13** and **86ms against 357ms**.

Fathom returns more output, not less, and that is the honest shape of the
result: it answers completely where grep returns a partial match list. Ask
which public functions reach `Credo.Code.Block.do_block_for!/1` and grep finds
the nine direct call sites, where the real answer is sixty-eight.

Grep wins on a repository you have just cloned and will ask two questions
about, because it needs no index. The build is a full forced compile: 2.5
seconds for Credo's 266 files, producing 79,057 facts.

Pass your own scenario file as a third argument to run it elsewhere. Scenarios
marked `requires:` are skipped when the project has no such facts, so the
Phoenix and Ecto questions drop out rather than counting as a win over an empty
table.

[credo]: https://github.com/rrrene/credo

## Is it correct?

`bench/verify_against_xref.sh` checks Fathom's references against `mix xref
callers`. That is a genuine oracle rather than a tautology: xref reads the same
compiler output through Mix's own manifests, not through a tracer. On every
module tried, Fathom found a strict superset of what xref found, the extra being
self-references, which xref excludes by design.

```
bench/verify_against_xref.sh /path/to/repo /path/to/program.db MyApp.Repo
```

## Incremental builds

Not yet. `mix fathom.build` is a full rebuild every time, which on a mid-sized
application costs under ten seconds.

The schema is already shaped for it: every table can be deleted by module, which
is the unit the compiler recompiles. An incremental build drops `--force`,
collects the modules that produced definitions this time round, deletes their
rows across every table, inserts the new facts, and purges any module with no
BEAM file left on disk. The compiler already propagates compile-time
dependencies, so it decides what to re-trace. The reason it is not here yet is
that the correctness bugs all live in that path, and a full rebuild that is
certainly right beats an incremental one that is subtly stale.

## License

MIT.
