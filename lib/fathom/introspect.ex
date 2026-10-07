defmodule Fathom.Introspect do
  @moduledoc """
  Post-compile reflection over the project's own modules.

  The tracer captures structure: who calls what, where things are defined. This
  pass captures meaning: documentation, typespecs, behaviours, and the facts
  that frameworks expose about themselves.

  The framework reflection is where a program database stops being a nicer
  `grep` and starts answering questions nothing else can. Ecto schemas know
  their table and their associations; a Phoenix router knows every route and
  the action behind it. With both in the same database as the call graph,
  "which HTTP endpoints eventually write to the `applications` table?" is a
  single query.

  Every framework probe is guarded by `function_exported?/3`, so a plain
  OTP application produces the general facts and simply no framework ones.
  """

  alias Fathom.Facts

  @doc """
  Runs every introspection pass over `modules` and buffers the resulting facts.
  """
  def run(modules) do
    Enum.each(modules, fn module ->
      ensure_loaded(module)

      docs(module)
      specs(module)
      callbacks(module)
      types(module)
      behaviours(module)
      protocol(module)
      ecto_schema(module)
      phoenix_router(module)
    end)
  end

  @doc """
  Lists the modules this project compiled, read from its build artefacts.

  Reading the BEAM directory rather than `Application.spec/2` keeps this
  working before the app is started, and keeps dependencies out of the results.
  """
  def project_modules(compile_path \\ Mix.Project.compile_path()) do
    compile_path
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".beam") |> String.to_atom()))
  end

  # -- general ---------------------------------------------------------------

  defp docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _lang, _format, module_doc, _meta, docs} ->
        if text = doc_text(module_doc) do
          Facts.put(module, {:module_doc, module, text})
        end

        for {{kind, name, arity}, _anno, signature, doc, _meta} <- docs,
            kind in [:function, :macro],
            text = doc_text(doc) do
          Facts.put(
            module,
            {:doc, {module, name, arity}, Enum.join(signature, " "), text}
          )
        end

        :ok

      _ ->
        :ok
    end
  end

  defp doc_text(%{} = doc), do: Map.get(doc, "en")
  defp doc_text(_), do: nil

  defp specs(module) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} ->
        Enum.each(specs, fn {{name, arity}, forms} ->
          Facts.put(module, {:spec, {module, name, arity}, spec_text(name, forms)})
        end)

      :error ->
        :ok
    end
  end

  defp spec_text(name, forms) do
    Enum.map_join(forms, "\n", fn form ->
      "@spec " <> Macro.to_string(Code.Typespec.spec_to_quoted(name, form))
    end)
  end

  defp callbacks(module) do
    case Code.Typespec.fetch_callbacks(module) do
      {:ok, callbacks} ->
        for {{name, arity}, forms} <- callbacks, form <- forms do
          text = "@callback " <> Macro.to_string(Code.Typespec.spec_to_quoted(name, form))
          Facts.put(module, {:callback_def, module, name, arity, text})
        end

        :ok

      :error ->
        :ok
    end
  end

  defp types(module) do
    case Code.Typespec.fetch_types(module) do
      {:ok, types} ->
        Enum.each(types, fn {kind, {name, _def, args} = type} ->
          text = "@#{kind} " <> Macro.to_string(Code.Typespec.type_to_quoted(type))
          Facts.put(module, {:type_def, module, name, length(args), kind, text})
        end)

      :error ->
        :ok
    end
  end

  defp behaviours(module) do
    for {:behaviour, mods} <- attributes(module), behaviour <- mods do
      Facts.put(module, {:behaviour, module, behaviour})
    end

    :ok
  end

  defp protocol(module) do
    cond do
      function_exported?(module, :__protocol__, 1) ->
        Facts.put(module, {:protocol, module})

      function_exported?(module, :__impl__, 1) ->
        Facts.put(
          module,
          {:impl, module.__impl__(:protocol), module.__impl__(:for), module}
        )

      true ->
        :ok
    end
  end

  # -- Ecto ------------------------------------------------------------------

  defp ecto_schema(module) do
    if function_exported?(module, :__schema__, 1) do
      # An `embedded_schema` has no table behind it, so its source stays NULL
      # and `WHERE source IS NOT NULL` means "backed by a real table".
      source = module.__schema__(:source)
      Facts.put(module, {:schema, module, source && to_string(source)})

      Enum.each(module.__schema__(:fields), fn field ->
        type = module.__schema__(:type, field)
        primary? = field in module.__schema__(:primary_key)
        Facts.put(module, {:schema_field, module, field, inspect(type), primary?})
      end)

      Enum.each(module.__schema__(:associations), fn name ->
        assoc = module.__schema__(:association, name)

        Facts.put(
          module,
          {:schema_assoc, module, name, assoc_cardinality(assoc), assoc_related(assoc)}
        )
      end)
    else
      :ok
    end
  end

  defp assoc_cardinality(%{cardinality: cardinality}), do: to_string(cardinality)
  defp assoc_cardinality(_), do: "unknown"

  defp assoc_related(%{related: related}) when is_atom(related), do: inspect(related)
  defp assoc_related(%{queryable: queryable}), do: inspect(queryable)
  defp assoc_related(_), do: nil

  # -- Phoenix ---------------------------------------------------------------

  defp phoenix_router(module) do
    if function_exported?(module, :__routes__, 0) do
      Enum.each(module.__routes__(), fn route ->
        Facts.put(
          module,
          {:route, module, to_string(route.verb), route.path, inspect(route.plug),
           to_string(route.plug_opts), route_helper(route)}
        )
      end)
    else
      :ok
    end
  end

  defp route_helper(%{helper: helper}) when is_binary(helper), do: helper
  defp route_helper(_), do: nil

  # -- helpers ---------------------------------------------------------------

  defp attributes(module) do
    if function_exported?(module, :module_info, 1) do
      module.module_info(:attributes)
    else
      []
    end
  rescue
    _ -> []
  end

  # Reflection degrades gracefully on a module that will not load, so the
  # result is deliberately not propagated.
  defp ensure_loaded(module) do
    _ = Code.ensure_loaded(module)
    :ok
  end
end
