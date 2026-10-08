defmodule FathomTest do
  @moduledoc """
  End-to-end tests over the sample application's program database.

  Everything here asserts against a real traced compilation rather than a
  hand-built fact list, because the parts most likely to break are the ones
  that depend on exactly what the compiler emits.
  """

  use ExUnit.Case, async: false

  import Fathom.Fixture

  setup_all do
    build!()
    :ok
  end

  describe "definitions" do
    test "records public and private functions with their kind" do
      kinds =
        Map.new(
          query("SELECT name, kind FROM functions WHERE module = 'SampleApp.Accounts'"),
          fn [name, kind] -> {name, kind} end
        )

      assert kinds["create_user"] == "def"
      assert kinds["build_user"] == "defp"
    end

    test "records macros, which do not survive into the BEAM file as functions" do
      assert one("SELECT kind FROM functions WHERE mfa = 'SampleApp.Web.render_inline/1'") ==
               "defmacro"
    end

    test "stores file paths relative to the project root" do
      assert one("SELECT file FROM functions WHERE mfa = 'SampleApp.Accounts.create_user/1'") ==
               "lib/sample_app.ex"
    end

    test "attaches docs and specs from post-compile introspection" do
      [[doc, spec]] =
        query("SELECT doc, spec FROM functions WHERE mfa = 'SampleApp.Accounts.create_user/1'")

      assert doc =~ "Creates a user"
      assert spec =~ "@spec create_user(map()) :: result()"
    end

    test "flags definitions a macro produced, including public and private ones" do
      assert generated("SampleApp.Injected.injected_one/0") == 1
      assert generated("SampleApp.Injected.injected_two/0") == 1
      assert generated("SampleApp.Injected.injected_private/0") == 1
      assert generated("SampleApp.Injected.injected_caller/0") == 1
    end

    test "flags a generated definition that shares its line with no other" do
      # The old heuristic marked a line only when five or more definitions
      # landed on it, so a macro injecting a single function read as written.
      assert generated("SampleApp.Injected.injected_solo/0") == 1
    end

    test "flags struct callbacks, which defstruct generates" do
      assert generated("SampleApp.User.__struct__/0") == 1
      assert generated("SampleApp.User.__struct__/1") == 1
    end

    test "does not flag a hand-written head whose defaults expand to several arities" do
      # Three arities from one written line: the inverse failure of a
      # heuristic that counts definitions sharing a line.
      assert generated("SampleApp.Injected.written_with_defaults/1") == 0
      assert generated("SampleApp.Injected.written_with_defaults/2") == 0
      assert generated("SampleApp.Injected.written_with_defaults/3") == 0
    end

    test "does not flag ordinary hand-written definitions" do
      assert generated("SampleApp.Injected.written_plain/0") == 0
      assert generated("SampleApp.Accounts.create_user/1") == 0
      assert generated("SampleApp.Accounts.build_user/1") == 0
    end
  end

  describe "call graph" do
    test "records a direct call" do
      assert one("""
             SELECT count(*) FROM calls
             WHERE caller = 'SampleApp.Accounts.delete_users/0'
               AND callee = 'SampleApp.Repo.delete_all/1'
             """) == 1
    end

    test "finds public entry points that reach a function transitively" do
      callers =
        column("""
        WITH RECURSIVE up(mfa) AS (
          SELECT caller FROM calls WHERE callee = 'SampleApp.Repo.delete_all/1'
          UNION
          SELECT c.caller FROM calls c JOIN up ON c.callee = up.mfa
        )
        SELECT f.mfa FROM functions f JOIN up USING (mfa) WHERE f.kind = 'def' ORDER BY f.mfa
        """)

      # The path runs through a private function, which is exactly the hop a
      # grep for `delete_all` would stop at.
      assert callers == [
               "SampleApp.AccountController.delete/2",
               "SampleApp.Accounts.purge_users/0",
               "SampleApp.Web.delete_account_action/1"
             ]
    end

    test "attributes references in a module body to the compile-time pseudo-function" do
      assert one("""
             SELECT count(*) FROM calls WHERE caller LIKE '%.__compile__/0'
             """) > 0
    end
  end

  describe "dynamic dispatch" do
    test "records apply/3 as a gap in the call graph" do
      assert one("""
             SELECT kind FROM dynamic_sites
             WHERE caller = 'SampleApp.Dispatcher.via_apply/2'
             """) == "apply"
    end

    test "records dispatch through a variable, which emits no trace event at all" do
      assert "SampleApp.Dispatcher.via_variable/2" in column(
               "SELECT caller FROM dynamic_sites WHERE kind = 'dynamic_module'"
             )
    end

    test "records dispatch through a module read from config" do
      assert "SampleApp.Dispatcher.via_config/1" in column(
               "SELECT caller FROM dynamic_sites WHERE kind = 'dynamic_module'"
             )
    end

    test "does not mistake map field access for a dynamic call" do
      refute "SampleApp.Dispatcher.static_field_access/1" in column(
               "SELECT caller FROM dynamic_sites"
             )
    end
  end

  describe "module metadata" do
    test "records behaviours" do
      assert "SampleApp.Behaviour" in column(
               "SELECT behaviour FROM behaviours WHERE module = 'SampleApp.Accounts'"
             )
    end

    test "records callbacks declared by a behaviour" do
      assert one("""
             SELECT spec FROM callbacks WHERE module = 'SampleApp.Behaviour' AND name = 'handle'
             """) =~ "@callback handle"
    end

    test "records protocol implementations" do
      assert query("SELECT protocol, for_type FROM impls") == [
               ["SampleApp.Describable", "SampleApp.User"]
             ]
    end

    test "records struct expansion sites" do
      assert "SampleApp.User" in column("SELECT struct_module FROM struct_uses")
    end

    test "records module docs" do
      assert one("SELECT doc FROM modules WHERE module = 'SampleApp.Accounts'") =~
               "The context module"
    end
  end

  describe "module dependencies" do
    test "classifies a struct expansion as a compile-time dependency" do
      assert one("""
             SELECT type FROM module_deps
             WHERE from_module = 'SampleApp.Accounts' AND to_module = 'SampleApp.User'
             """) == "compile"
    end

    test "classifies a call from a function body as a runtime dependency" do
      assert one("""
             SELECT type FROM module_deps
             WHERE from_module = 'SampleApp.Accounts' AND to_module = 'SampleApp.Repo'
             """) == "runtime"
    end
  end

  describe "framework reflection" do
    test "records the table behind a schema" do
      assert one("SELECT source FROM schemas WHERE module = 'SampleApp.Schemas.Account'") ==
               "accounts"
    end

    test "leaves source null for an embedded schema, which has no table" do
      assert one("SELECT source FROM schemas WHERE module = 'SampleApp.Schemas.Address'") == nil

      assert column("SELECT module FROM schemas WHERE source IS NOT NULL ORDER BY module") == [
               "SampleApp.Schemas.Account",
               "SampleApp.Schemas.Post"
             ]
    end

    test "records fields with their types and which are the primary key" do
      fields =
        Map.new(
          query("""
          SELECT field, type || '/' || primary_key FROM schema_fields
          WHERE module = 'SampleApp.Schemas.Account'
          """),
          fn [field, rest] -> {field, rest} end
        )

      assert fields["id"] == ":id/1"
      assert fields["email"] == ":string/0"
    end

    test "records associations and what they point at" do
      assert query("""
             SELECT name, cardinality, related FROM schema_assocs
             WHERE module = 'SampleApp.Schemas.Account'
             """) == [["posts", "many", "SampleApp.Schemas.Post"]]
    end

    test "records routes with the action behind them" do
      assert query("SELECT verb, path, plug, action FROM routes ORDER BY path, verb") == [
               ["get", "/accounts", "SampleApp.AccountController", "index"],
               ["delete", "/accounts/:id", "SampleApp.AccountController", "delete"]
             ]
    end

    test "joins routes to the call graph to find endpoints reaching a table" do
      # The join no other single tool can make: the router knows the route, the
      # call graph knows the path from the action down, and Ecto knows which
      # schema backs which table.
      endpoints =
        column("""
        WITH RECURSIVE reach(path, mfa) AS (
          SELECT r.path, r.plug || '.' || r.action || '/2' FROM routes r
          UNION
          SELECT re.path, c.callee FROM calls c JOIN reach re ON c.caller = re.mfa
        )
        SELECT DISTINCT re.path FROM reach re
        WHERE re.mfa = 'SampleApp.Repo.delete_all/1'
        """)

      assert endpoints == ["/accounts/:id"]
    end
  end

  describe "metadata" do
    test "records which project and toolchain produced the database" do
      meta = Map.new(query("SELECT key, value FROM meta"), fn [k, v] -> {k, v} end)

      assert meta["project"] == "sample_app"
      assert meta["elixir_version"] == System.version()
    end
  end
end
