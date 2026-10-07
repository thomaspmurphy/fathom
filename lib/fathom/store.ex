defmodule Fathom.Store do
  @moduledoc """
  Writes buffered facts into a SQLite file.

  The whole dump is one transaction with journalling disabled. The database is
  a derived artefact rebuilt from scratch on every run, so there is nothing to
  protect against a crash halfway through: if the build dies you re-run it.
  That buys roughly an order of magnitude over the default durable settings on
  a few million rows.

  Indexes are created after the load rather than before. Module and file names
  repeat constantly across facts, so both are memoised while folding; without
  that, `inspect/1` on module atoms dominates the dump.

  `update/4` is the incremental counterpart. It keeps the same load path but
  reuses an existing file, deleting the rows owned by every module the
  compiler touched before inserting their replacements. It does not disable
  journalling: a full write throws the file away on failure, whereas an
  update has to leave the previous database intact.
  """

  alias Exqlite.Sqlite3
  alias Fathom.{Facts, Schema}

  @bulk_pragmas [
    "PRAGMA journal_mode = OFF",
    "PRAGMA synchronous = OFF",
    "PRAGMA temp_store = MEMORY",
    "PRAGMA cache_size = -64000",
    "PRAGMA locking_mode = EXCLUSIVE"
  ]

  # An update rewrites part of a database the caller wants to keep, so the
  # journal stays on and the whole thing rides on one transaction. The two
  # pragmas that only buy speed are still worth setting.
  @update_pragmas [
    "PRAGMA temp_store = MEMORY",
    "PRAGMA cache_size = -64000"
  ]

  @doc """
  Builds the database at `path` from the facts currently buffered.

  `root` is the project directory; file paths are stored relative to it so the
  database is portable and the paths are the ones an agent can open directly.
  """
  def write(path, root, meta \\ %{}) do
    # The database and its sidecars may not be there at all on a first build,
    # so these are best-effort by design.
    Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    File.mkdir_p!(Path.dirname(path))

    {:ok, conn} = Sqlite3.open(path)

    try do
      Enum.each(@bulk_pragmas, &exec!(conn, &1))
      Enum.each(Schema.create_table_statements(), &exec!(conn, &1))

      exec!(conn, "BEGIN")
      counts = populate(conn, root)
      # `counts` is what this dump inserted, which omits the tables derived in
      # SQL afterwards. `fact_counts` is meant to describe the database, so it
      # is read back for both write paths rather than differing between them.
      write_meta(conn, meta, table_counts(conn))
      exec!(conn, "COMMIT")

      Enum.each(Schema.create_index_statements(), &exec!(conn, &1))
      exec!(conn, "ANALYZE")
      exec!(conn, "PRAGMA journal_mode = DELETE")
      exec!(conn, "VACUUM")

      {:ok, counts}
    after
      Sqlite3.close(conn)
    end
  end

  @doc """
  Updates the database at `path` in place from the facts currently buffered.

  `scope` describes what the compiler did:

    * `:recompiled` - the modules that were compiled this round, whose rows are
      deleted before the new facts are inserted
    * `:live` - every module that still has a BEAM file, used to purge modules
      whose source was deleted or renamed

  Returns `{:ok, counts, removed}`, where `counts` is what this round inserted
  and `removed` is the modules whose rows were dropped.

  The caller is responsible for falling back to `write/3` when `path` does not
  exist yet; there is nothing to update into.
  """
  def update(path, root, scope, meta \\ %{}) do
    # Opening a missing file would hand back an empty database and fail on the
    # first table that is not there, several steps from the actual mistake.
    File.exists?(path) ||
      raise ArgumentError, "no database at #{path} to update; use write/3 for the first build"

    {:ok, conn} = Sqlite3.open(path)

    try do
      Enum.each(@update_pragmas, &exec!(conn, &1))

      exec!(conn, "BEGIN")

      recompiled = Enum.map(scope.recompiled, &module_string/1)
      purged = purged_modules(conn, scope.live)
      removed = Enum.uniq(recompiled ++ purged)
      delete_modules(conn, removed, purged)

      counts = populate(conn, root)
      write_meta(conn, meta, table_counts(conn))
      exec!(conn, "COMMIT")

      exec!(conn, "ANALYZE")

      {:ok, counts, removed}
    after
      Sqlite3.close(conn)
    end
  end

  # -- loading ---------------------------------------------------------------

  defp populate(conn, root) do
    inserts = prepare_inserts(conn)
    updates = prepare_updates(conn)

    counts = load_facts(conn, inserts, root)
    mark_generated(conn)
    seed_modules(conn)
    apply_updates(conn, updates)
    derive_module_deps(conn)

    release_all(conn, inserts)
    release_all(conn, updates)

    counts
  end

  defp load_facts(conn, inserts, root) do
    Facts.reduce(%{}, fn fact, counts ->
      case row(fact, root) do
        {table, values} ->
          run(conn, Map.fetch!(inserts, table), values)
          Map.update(counts, table, 1, &(&1 + 1))

        :skip ->
          counts
      end
    end)
  end

  defp apply_updates(conn, updates) do
    Facts.reduce(:ok, fn
      {:doc, mfa, signature, text}, acc ->
        run(conn, updates.function_doc, [text, signature, mfa_string(mfa)])
        acc

      {:spec, mfa, text}, acc ->
        run(conn, updates.function_spec, [text, mfa_string(mfa)])
        acc

      {:module_doc, module, text}, acc ->
        run(conn, updates.module_doc, [module_string(module), text])
        acc

      _other, acc ->
        acc
    end)
  end

  # -- incremental deletion --------------------------------------------------

  # A module the database knows about that no longer has a BEAM file behind it
  # has had its source deleted or renamed. Nothing will recompile it, so
  # nothing else would ever remove its rows.
  #
  # `modules` is the index of what the database knows, since every module that
  # defines anything is seeded into it.
  defp purged_modules(conn, live) do
    live = MapSet.new(live, &module_string/1)

    conn
    |> fetch_column("SELECT module FROM modules")
    |> Enum.reject(&MapSet.member?(live, &1))
  end

  defp delete_modules(conn, removed, purged) do
    deletes =
      Map.new(Schema.module_scoped_tables(), fn {table, _column} ->
        {:ok, stmt} = Sqlite3.prepare(conn, Schema.delete_by_module_statement(table))
        {table, stmt}
      end)

    Enum.each(removed, fn module ->
      Enum.each(deletes, fn {_table, stmt} -> run(conn, stmt, [module]) end)
    end)

    # A dependency edge is deleted along with the module it leaves, so a module
    # that was merely recompiled gets its outgoing edges rebuilt from this
    # round's facts. A module that is gone also leaves edges pointing *at* it,
    # held by modules the compiler had no reason to touch, and those would
    # otherwise survive as references to something that no longer exists.
    {:ok, inbound} = Sqlite3.prepare(conn, "DELETE FROM module_deps WHERE to_module = ?")
    Enum.each(purged, &run(conn, inbound, [&1]))
    release!(conn, inbound)

    release_all(conn, deletes)
  end

  # -- fact to row -----------------------------------------------------------

  defp row({:definition, mfa, kind, file, line}, root) do
    {module, name, arity} = mfa

    {:functions,
     [
       mfa_string(mfa),
       module_string(module),
       to_string(name),
       arity,
       to_string(kind),
       rel(file, root),
       line,
       nil,
       nil,
       nil,
       0
     ]}
  end

  defp row({:call, caller, callee, kind, file, line}, root) do
    {callee_module, callee_name, callee_arity} = callee

    {:calls,
     [
       mfa_string(caller),
       module_string(elem(caller, 0)),
       mfa_string(callee),
       module_string(callee_module),
       to_string(callee_name),
       callee_arity,
       to_string(kind),
       rel(file, root),
       line
     ]}
  end

  defp row({:dynamic_site, caller, kind, file, line}, root) do
    {:dynamic_sites,
     [mfa_string(caller), module_string(elem(caller, 0)), to_string(kind), rel(file, root), line]}
  end

  defp row({:struct_use, caller, module, keys, file, line}, root) do
    {:struct_uses,
     [
       mfa_string(caller),
       module_string(elem(caller, 0)),
       module_string(module),
       keys_string(keys),
       rel(file, root),
       line
     ]}
  end

  defp row({:alias_ref, caller, module, file, line}, root) do
    {:alias_refs,
     [
       mfa_string(caller),
       module_string(elem(caller, 0)),
       module_string(module),
       rel(file, root),
       line
     ]}
  end

  defp row({:use_site, module, used_module, file, line}, root) do
    {:use_sites, [module_string(module), module_string(used_module), rel(file, root), line]}
  end

  defp row({:compile_env, caller, app, path, file, line}, root) do
    {:compile_envs,
     [
       mfa_string(caller),
       module_string(elem(caller, 0)),
       to_string(app),
       inspect(path),
       rel(file, root),
       line
     ]}
  end

  defp row({:behaviour, module, behaviour}, _root) do
    {:behaviours, [module_string(module), module_string(behaviour)]}
  end

  defp row({:callback_def, module, name, arity, spec}, _root) do
    {:callbacks, [module_string(module), to_string(name), arity, spec]}
  end

  defp row({:type_def, module, name, arity, kind, spec}, _root) do
    {:types, [module_string(module), to_string(name), arity, to_string(kind), spec]}
  end

  defp row({:impl, protocol, for_type, module}, _root) do
    {:impls, [module_string(protocol), module_string(for_type), module_string(module)]}
  end

  defp row({:schema, module, source}, _root) do
    {:schemas, [module_string(module), source]}
  end

  defp row({:schema_field, module, field, type, primary?}, _root) do
    {:schema_fields, [module_string(module), to_string(field), type, bool(primary?)]}
  end

  defp row({:schema_assoc, module, name, cardinality, related}, _root) do
    {:schema_assocs, [module_string(module), to_string(name), cardinality, related]}
  end

  defp row({:route, router, verb, path, plug, action, helper}, _root) do
    {:routes, [module_string(router), verb, path, plug, action, helper]}
  end

  # Docs and specs amend rows written by the definition pass, and `:protocol`
  # is covered by the modules table, so neither inserts anything here.
  defp row(_fact, _root), do: :skip

  # -- derived tables --------------------------------------------------------

  # A macro-generated definition reports the line of the macro that produced
  # it, so `use Ecto.Repo` leaves seventy-odd functions all claiming the same
  # line. Nothing else does that: you cannot write five `def`s on one line of
  # Elixir. Marking them matters because they otherwise swamp any question
  # about the code someone actually wrote — `use Ecto.Repo` alone contributes
  # fifty uncalled public functions to a naive dead-code query.
  @generated_threshold 5

  defp mark_generated(conn) do
    exec!(conn, """
    UPDATE functions SET generated = 1
    WHERE (file, line) IN (
      SELECT file, line FROM functions
      GROUP BY file, line HAVING count(*) >= #{@generated_threshold}
    )
    """)
  end

  defp seed_modules(conn) do
    exec!(conn, """
    INSERT OR IGNORE INTO modules (module, file, doc)
    SELECT module, MIN(file), NULL FROM functions GROUP BY module
    """)
  end

  # A reference made from a module body runs while the file is being compiled,
  # which makes it a compile-time dependency; the same reference inside a
  # function body does not. Macro expansion, struct expansion and `use` are
  # compile-time by construction. This mirrors how `mix xref` classifies edges,
  # at the cost of being an approximation in both directions.
  defp derive_module_deps(conn) do
    exec!(conn, """
    INSERT OR IGNORE INTO module_deps (from_module, to_module, type)
    SELECT DISTINCT caller_module, callee_module,
      CASE
        WHEN kind IN ('remote_macro', 'imported_macro') THEN 'compile'
        WHEN caller LIKE '%.__compile__/0' THEN 'compile'
        ELSE 'runtime'
      END
    FROM calls
    WHERE caller_module <> callee_module
    """)

    exec!(conn, """
    INSERT OR IGNORE INTO module_deps (from_module, to_module, type)
    SELECT DISTINCT caller_module, struct_module, 'compile'
    FROM struct_uses WHERE caller_module <> struct_module
    """)

    exec!(conn, """
    INSERT OR IGNORE INTO module_deps (from_module, to_module, type)
    SELECT DISTINCT module, used_module, 'compile'
    FROM use_sites WHERE module <> used_module
    """)
  end

  # After a full write the facts inserted are the facts in the database, but
  # after an update they are only the slice that changed. `fact_counts` is
  # meant to describe the database, so an update reads it back rather than
  # recording what it happened to insert.
  defp table_counts(conn) do
    for {table, _cols} <- Schema.tables(), table != :meta, into: %{} do
      {table, conn |> fetch_column("SELECT count(*) FROM #{table}") |> hd()}
    end
  end

  defp write_meta(conn, meta, counts) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)"
      )

    rows =
      meta
      |> Map.put(:fact_counts, inspect(Enum.sort(counts)))
      |> Map.put(:elixir_version, System.version())
      |> Map.put(:otp_release, System.otp_release())

    Enum.each(rows, fn {key, value} -> run(conn, stmt, [to_string(key), to_string(value)]) end)
    release!(conn, stmt)
  end

  # -- statement plumbing ----------------------------------------------------

  defp prepare_inserts(conn) do
    Map.new(Schema.tables(), fn {table, _cols} ->
      {:ok, stmt} = Sqlite3.prepare(conn, Schema.insert_statement(table))
      {table, stmt}
    end)
  end

  defp prepare_updates(conn) do
    {:ok, function_doc} =
      Sqlite3.prepare(conn, "UPDATE functions SET doc = ?, signature = ? WHERE mfa = ?")

    {:ok, function_spec} =
      Sqlite3.prepare(conn, "UPDATE functions SET spec = ? WHERE mfa = ?")

    {:ok, module_doc} =
      Sqlite3.prepare(conn, """
      INSERT INTO modules (module, doc) VALUES (?, ?)
      ON CONFLICT(module) DO UPDATE SET doc = excluded.doc
      """)

    %{function_doc: function_doc, function_spec: function_spec, module_doc: module_doc}
  end

  defp release_all(conn, statements) do
    Enum.each(statements, fn {_key, stmt} -> release!(conn, stmt) end)
  end

  defp fetch_column(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    release!(conn, stmt)
    Enum.map(rows, &hd/1)
  end

  # Every statement is asserted. A failed `execute` that is thrown away leaves
  # a database that is missing rows and says nothing about it, which is the
  # exact failure this whole module is built to avoid.
  defp exec!(conn, sql), do: :ok = Sqlite3.execute(conn, sql)

  defp release!(conn, stmt), do: :ok = Sqlite3.release(conn, stmt)

  defp run(conn, stmt, values) do
    :ok = Sqlite3.reset(stmt)
    :ok = Sqlite3.bind(stmt, values)
    :done = Sqlite3.step(conn, stmt)
    :ok
  end

  # -- formatting ------------------------------------------------------------

  @doc "Formats an MFA tuple the way the database stores it."
  def mfa_string({module, name, arity}) do
    module_string(module) <> "." <> Atom.to_string(name) <> "/" <> Integer.to_string(arity)
  end

  defp module_string(module) when is_atom(module) do
    case Process.get({:fathom_mod, module}) do
      nil ->
        string = inspect(module)
        Process.put({:fathom_mod, module}, string)
        string

      cached ->
        cached
    end
  end

  defp module_string(other), do: to_string(other)

  defp rel(nil, _root), do: nil

  defp rel(file, root) do
    case Process.get({:fathom_file, file}) do
      nil ->
        string = Path.relative_to(file, root)
        Process.put({:fathom_file, file}, string)
        string

      cached ->
        cached
    end
  end

  defp keys_string(keys) when is_list(keys), do: Enum.map_join(keys, ",", &to_string/1)
  defp keys_string(_), do: nil

  defp bool(true), do: 1
  defp bool(_), do: 0
end
