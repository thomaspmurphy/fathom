defmodule Fathom.Dynamic do
  @moduledoc """
  Finds dispatch sites that the compiler tracer is structurally unable to see.

  When you write `mod.handle(arg)` and `mod` is a variable, the compiler never
  resolves a module, so no `:remote_function` event is emitted and no edge
  appears in the call graph. The same is true of `apply/3` with a computed
  module and of a function name held in a variable.

  These are the places where a call graph quietly stops being complete, so
  Fathom records them as facts in their own right. An agent that asks "who
  calls this?" can also ask "does this module dispatch dynamically?" and know
  how far to trust the answer.
  """

  @type site :: {line :: non_neg_integer(), kind :: :dynamic_module | :dynamic_function}

  @doc """
  Walks an expanded AST body and returns the dynamic dispatch sites in it.

  Returns `{line, kind}` pairs, where kind is `:dynamic_module` when the module
  half of the dot is computed and `:dynamic_function` when the function name is.
  """
  @spec sites(Macro.t()) :: [site()]
  def sites(body) do
    {_ast, found} = Macro.prewalk(body, [], &collect/2)
    Enum.reverse(found)
  end

  # `foo.bar` without parens is map/struct field access, not a call.
  defp collect({{:., _, [_, _]}, call_meta, _args} = node, acc) do
    if Keyword.get(call_meta, :no_parens, false) do
      {node, acc}
    else
      {node, classify(node, acc)}
    end
  end

  defp collect(node, acc), do: {node, acc}

  defp classify({{:., dot_meta, [left, right]}, call_meta, _args}, acc) do
    line = Keyword.get(call_meta, :line) || Keyword.get(dot_meta, :line, 0)

    cond do
      static_module?(left) and is_atom(right) -> acc
      not static_module?(left) -> [{line, :dynamic_module} | acc]
      true -> [{line, :dynamic_function} | acc]
    end
  end

  # Definition bodies come back expanded, so an alias is already an atom. The
  # unexpanded form is accepted too so the walk can be reused on raw AST.
  defp static_module?(mod) when is_atom(mod), do: true
  defp static_module?({:__aliases__, _, _}), do: true
  defp static_module?(_), do: false
end
