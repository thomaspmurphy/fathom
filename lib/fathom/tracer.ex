defmodule Fathom.Tracer do
  @moduledoc """
  Compiler tracer that records every resolved reference in the project.

  Pass it to the compiler with `--tracer Fathom.Tracer`. The compiler invokes
  `trace/2` after macro expansion, so what lands in the database is what `use`,
  `import` and framework macros actually generated, not the surface syntax. A
  `use Phoenix.LiveView` that expands into a dozen callbacks produces a dozen
  definitions here.

  Everything runs inside the compiler's processes, so each clause does the
  minimum work needed to build a tuple and hand it to `Fathom.Facts`.

  ## The caller of a top-level reference

  References in a module body have no enclosing function. They are attributed
  to the pseudo-function `__compile__/0` on that module, which is also how they
  are distinguished from runtime references when deriving module dependencies:
  anything reached from `__compile__/0` is a compile-time dependency.
  """

  alias Fathom.{Dynamic, Facts}

  @call_kinds [:remote_function, :remote_macro, :imported_function, :imported_macro]

  # Modules whose presence means the static call graph is incomplete from here on.
  @dynamic_dispatch [{Kernel, :apply}, {:erlang, :apply}]
  @eval_dispatch [{Code, :eval_string}, {Code, :eval_quoted}, {Code, :eval_file}]

  @doc false
  def trace({kind, meta, mod, name, arity}, env) when kind in @call_kinds do
    record_call(kind, {mod, name, arity}, meta, env)
  end

  def trace({kind, meta, name, arity}, env) when kind in [:local_function, :local_macro] do
    record_call(kind, {env.module, name, arity}, meta, env)
  end

  def trace({:struct_expansion, meta, mod, keys}, env) do
    Facts.put(env.module, {:struct_use, caller(env), mod, keys, env.file, line(meta)})
  end

  def trace({:alias_reference, meta, mod}, env) do
    Facts.put(env.module, {:alias_ref, caller(env), mod, env.file, line(meta)})
  end

  def trace({:compile_env, app, path, _return}, env) do
    Facts.put(env.module, {:compile_env, caller(env), app, path, env.file, env.line})
  end

  def trace({:on_module, _bytecode, _ignore}, env) do
    module = env.module

    for {name, arity} <- Module.definitions_in(module) do
      case Module.get_definition(module, {name, arity}) do
        {:v1, kind, meta, clauses} ->
          Facts.put(
            module,
            {:definition, {module, name, arity}, kind, env.file, line(meta), generated?(meta)}
          )

          scan_clauses(clauses, {module, name, arity}, env)

        _other ->
          :ok
      end
    end

    :ok
  end

  def trace(_event, _env), do: :ok

  # -- call recording -------------------------------------------------------

  defp record_call(kind, {mod, name, _arity} = callee, meta, env) do
    from = caller(env)
    Facts.put(env.module, {:call, from, callee, kind, env.file, line(meta)})

    cond do
      {mod, name} in @dynamic_dispatch ->
        Facts.put(env.module, {:dynamic_site, from, :apply, env.file, line(meta)})

      {mod, name} in @eval_dispatch ->
        Facts.put(env.module, {:dynamic_site, from, :eval, env.file, line(meta)})

      name == :__using__ ->
        Facts.put(env.module, {:use_site, env.module, mod, env.file, line(meta)})

      true ->
        :ok
    end
  end

  # -- dynamic dispatch the tracer cannot see -------------------------------

  # `mod.fun()` where `mod` is a variable emits no trace event at all: the
  # compiler never resolves a module, so there is nothing to report. Those
  # sites only exist in the AST, which is still reachable while the module is
  # open, so we walk the definition bodies for them. Recording the gap is more
  # useful than presenting the call graph as complete.
  defp scan_clauses(clauses, mfa, env) do
    for {_meta, _args, _guards, body} <- clauses,
        {line, kind} <- Dynamic.sites(body) do
      Facts.put(env.module, {:dynamic_site, mfa, kind, env.file, line})
    end

    :ok
  end

  # -- helpers --------------------------------------------------------------

  # A reference outside any function belongs to the module body, which the
  # compiler executes at compile time.
  defp caller(%{function: nil, module: module}), do: {module, :__compile__, 0}
  defp caller(%{function: {name, arity}, module: module}), do: {module, name, arity}

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line(_), do: 0

  # Whether a macro produced this definition, taken from the compiler rather
  # than guessed. `Module.get_definition/2` tags a definition that came from a
  # macro expansion with the expanding context (`context: Ecto.Repo`,
  # `context: Kernel` for `defstruct`); one the author typed carries `column:`
  # and no context. This distinguishes the two cases a line-collision heuristic
  # cannot: a macro that injects a single function is still generated, and a
  # head with default arguments produces several arities on one line that are
  # all hand-written.
  defp generated?(meta) when is_list(meta), do: Keyword.has_key?(meta, :context)
  defp generated?(_), do: false
end
