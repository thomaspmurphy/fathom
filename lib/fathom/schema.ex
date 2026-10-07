defmodule Fathom.Schema do
  @moduledoc """
  The shape of the program database.

  The schema is deliberately boring and denormalised. It is written to be read
  by something that gets one attempt at the query and cannot see the result of
  a `.schema` call first, so every table carries the columns you would
  otherwise have to join for. A call row knows the caller's module as well as
  the full `mfa` string; a function row knows its module, name and arity as
  well as the `mfa` that joins against everything else.

  `mfa` strings are formatted as `"MyApp.Accounts.create_user/2"`, and are the
  join key throughout.
  """

  @tables [
    {:modules,
     [
       {"module", "TEXT PRIMARY KEY"},
       {"file", "TEXT"},
       {"doc", "TEXT"}
     ]},
    {:functions,
     [
       {"mfa", "TEXT PRIMARY KEY"},
       {"module", "TEXT NOT NULL"},
       {"name", "TEXT NOT NULL"},
       {"arity", "INTEGER NOT NULL"},
       {"kind", "TEXT NOT NULL"},
       {"file", "TEXT"},
       {"line", "INTEGER"},
       {"signature", "TEXT"},
       {"doc", "TEXT"},
       {"spec", "TEXT"},
       # 1 when the definition came from a macro rather than being written out.
       # See `Fathom.Store` for how this is decided.
       {"generated", "INTEGER NOT NULL DEFAULT 0"}
     ]},
    {:calls,
     [
       {"caller", "TEXT NOT NULL"},
       {"caller_module", "TEXT NOT NULL"},
       {"callee", "TEXT NOT NULL"},
       {"callee_module", "TEXT NOT NULL"},
       {"callee_name", "TEXT NOT NULL"},
       {"callee_arity", "INTEGER NOT NULL"},
       {"kind", "TEXT NOT NULL"},
       {"file", "TEXT"},
       {"line", "INTEGER"}
     ]},
    {:dynamic_sites,
     [
       {"caller", "TEXT NOT NULL"},
       {"caller_module", "TEXT NOT NULL"},
       {"kind", "TEXT NOT NULL"},
       {"file", "TEXT"},
       {"line", "INTEGER"}
     ]},
    {:struct_uses,
     [
       {"caller", "TEXT NOT NULL"},
       {"caller_module", "TEXT NOT NULL"},
       {"struct_module", "TEXT NOT NULL"},
       {"keys", "TEXT"},
       {"file", "TEXT"},
       {"line", "INTEGER"}
     ]},
    {:alias_refs,
     [
       {"caller", "TEXT NOT NULL"},
       {"caller_module", "TEXT NOT NULL"},
       {"module", "TEXT NOT NULL"},
       {"file", "TEXT"},
       {"line", "INTEGER"}
     ]},
    {:use_sites,
     [
       {"module", "TEXT NOT NULL"},
       {"used_module", "TEXT NOT NULL"},
       {"file", "TEXT"},
       {"line", "INTEGER"}
     ]},
    {:compile_envs,
     [
       {"caller", "TEXT NOT NULL"},
       {"caller_module", "TEXT NOT NULL"},
       {"app", "TEXT NOT NULL"},
       {"path", "TEXT"},
       {"file", "TEXT"},
       {"line", "INTEGER"}
     ]},
    {:behaviours,
     [
       {"module", "TEXT NOT NULL"},
       {"behaviour", "TEXT NOT NULL"}
     ]},
    {:callbacks,
     [
       {"module", "TEXT NOT NULL"},
       {"name", "TEXT NOT NULL"},
       {"arity", "INTEGER NOT NULL"},
       {"spec", "TEXT"}
     ]},
    {:types,
     [
       {"module", "TEXT NOT NULL"},
       {"name", "TEXT NOT NULL"},
       {"arity", "INTEGER NOT NULL"},
       {"kind", "TEXT NOT NULL"},
       {"spec", "TEXT"}
     ]},
    {:impls,
     [
       {"protocol", "TEXT NOT NULL"},
       {"for_type", "TEXT NOT NULL"},
       {"module", "TEXT NOT NULL"}
     ]},
    {:schemas,
     [
       {"module", "TEXT PRIMARY KEY"},
       # NULL for an embedded_schema, which has no table behind it.
       {"source", "TEXT"}
     ]},
    {:schema_fields,
     [
       {"module", "TEXT NOT NULL"},
       {"field", "TEXT NOT NULL"},
       {"type", "TEXT"},
       {"primary_key", "INTEGER"}
     ]},
    {:schema_assocs,
     [
       {"module", "TEXT NOT NULL"},
       {"name", "TEXT NOT NULL"},
       {"cardinality", "TEXT"},
       {"related", "TEXT"}
     ]},
    {:routes,
     [
       {"router", "TEXT NOT NULL"},
       {"verb", "TEXT NOT NULL"},
       {"path", "TEXT NOT NULL"},
       {"plug", "TEXT NOT NULL"},
       {"action", "TEXT"},
       {"helper", "TEXT"}
     ]},
    {:module_deps,
     [
       {"from_module", "TEXT NOT NULL"},
       {"to_module", "TEXT NOT NULL"},
       {"type", "TEXT NOT NULL"}
     ]},
    {:meta,
     [
       {"key", "TEXT PRIMARY KEY"},
       {"value", "TEXT"}
     ]}
  ]

  # Which column holds the module a row belongs to, for every table that is
  # owned by one. This is what makes an incremental build possible: the unit
  # the compiler recompiles is a module, so the unit the database deletes has
  # to be a module too.
  #
  # `meta` is absent because it describes the build rather than any module.
  # `impls` is keyed on the implementation module (`Describable.User`), which
  # is itself a compiled module, so it is deleted with the file that defines
  # it rather than with the protocol or the type.
  @module_columns %{
    modules: "module",
    functions: "module",
    calls: "caller_module",
    dynamic_sites: "caller_module",
    struct_uses: "caller_module",
    alias_refs: "caller_module",
    use_sites: "module",
    compile_envs: "caller_module",
    behaviours: "module",
    callbacks: "module",
    types: "module",
    impls: "module",
    schemas: "module",
    schema_fields: "module",
    schema_assocs: "module",
    routes: "router",
    module_deps: "from_module"
  }

  @indexes [
    "CREATE INDEX idx_functions_module ON functions(module)",
    "CREATE INDEX idx_functions_name ON functions(name)",
    "CREATE INDEX idx_functions_generated ON functions(generated)",
    "CREATE INDEX idx_calls_callee ON calls(callee)",
    "CREATE INDEX idx_calls_caller ON calls(caller)",
    "CREATE INDEX idx_calls_callee_module ON calls(callee_module)",
    "CREATE INDEX idx_calls_caller_module ON calls(caller_module)",
    "CREATE INDEX idx_dynamic_sites_module ON dynamic_sites(caller_module)",
    "CREATE INDEX idx_struct_uses_module ON struct_uses(struct_module)",
    "CREATE INDEX idx_alias_refs_module ON alias_refs(module)",
    "CREATE INDEX idx_use_sites_used ON use_sites(used_module)",
    "CREATE INDEX idx_behaviours_behaviour ON behaviours(behaviour)",
    "CREATE INDEX idx_impls_protocol ON impls(protocol)",
    "CREATE INDEX idx_schema_fields_module ON schema_fields(module)",
    "CREATE INDEX idx_schema_assocs_related ON schema_assocs(related)",
    "CREATE INDEX idx_routes_plug ON routes(plug)",
    "CREATE UNIQUE INDEX idx_module_deps ON module_deps(from_module, to_module, type)"
  ]

  @doc "The table definitions as `{name, [{column, type}]}` pairs."
  def tables, do: @tables

  @doc "Column names for a table."
  def columns(table) do
    {^table, cols} = List.keyfind(@tables, table, 0)
    Enum.map(cols, &elem(&1, 0))
  end

  @doc "`CREATE TABLE` statements for every table."
  def create_table_statements do
    for {name, cols} <- @tables do
      body = Enum.map_join(cols, ", ", fn {col, type} -> "#{col} #{type}" end)
      "CREATE TABLE #{name} (#{body})"
    end
  end

  @doc """
  `CREATE INDEX` statements.

  These are applied after the bulk load rather than before it. Maintaining
  sixteen indexes across a few million inserts costs considerably more than
  building them once over finished tables.
  """
  def create_index_statements, do: @indexes

  # A table added without a matching entry above would silently keep its rows
  # across an incremental build, which is the worst kind of staleness: a
  # database that looks complete and is not. Catch it at compile time instead.
  @uncovered Enum.map(@tables, &elem(&1, 0)) -- [:meta | Map.keys(@module_columns)]
  if @uncovered != [] do
    raise "tables with no entry in @module_columns: #{inspect(@uncovered)}"
  end

  @doc """
  Tables owned by a module, as `{table, module_column}` pairs.

  Every table except `meta` belongs to exactly one module, though not all of
  them name that column the same way.
  """
  def module_scoped_tables, do: Map.to_list(@module_columns)

  @doc """
  A `DELETE` removing every row a module owns from `table`.

  Parameterised on the module name, so one prepared statement serves every
  module in a rebuild.
  """
  def delete_by_module_statement(table) do
    "DELETE FROM #{table} WHERE #{Map.fetch!(@module_columns, table)} = ?"
  end

  @doc "A parameterised `INSERT` for a table, with one placeholder per column."
  def insert_statement(table) do
    cols = columns(table)
    placeholders = Enum.map_join(cols, ", ", fn _ -> "?" end)
    "INSERT INTO #{table} (#{Enum.join(cols, ", ")}) VALUES (#{placeholders})"
  end

  @doc "The schema rendered as DDL, for embedding in agent-facing documentation."
  def to_ddl do
    Enum.map_join(create_table_statements(), ";\n", & &1) <> ";"
  end
end
