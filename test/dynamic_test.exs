defmodule Fathom.DynamicTest do
  @moduledoc """
  Unit tests for the AST walk, which runs on expanded definition bodies and so
  is easiest to pin down directly.
  """

  use ExUnit.Case, async: true

  alias Fathom.Dynamic

  defp sites(code), do: code |> Code.string_to_quoted!() |> Dynamic.sites()

  test "flags a call on a variable module" do
    assert [{1, :dynamic_module}] = sites("mod.handle(arg)")
  end

  test "flags a call on the result of an expression" do
    assert [{1, :dynamic_module}] = sites("Module.concat(a, b).handle(arg)")
  end

  test "ignores a call on a literal module" do
    assert [] = sites(":erlang.length(list)")
  end

  test "ignores a call on an aliased module" do
    assert [] = sites("MyApp.Accounts.create_user(attrs)")
  end

  test "ignores map and struct field access" do
    assert [] = sites("user.name")
    assert [] = sites("conn.assigns.current_user")
  end

  test "ignores an anonymous function call" do
    assert [] = sites("fun.(arg)")
  end

  test "reports the line of each site" do
    code = """
    def run(mod) do
      mod.first()
      MyApp.second()
      mod.third()
    end
    """

    assert [{2, :dynamic_module}, {4, :dynamic_module}] = sites(code)
  end

  test "walks into nested expressions" do
    code = """
    case thing do
      :a -> mod.handle(1)
      :b -> :ok
    end
    """

    assert [{2, :dynamic_module}] = sites(code)
  end
end
