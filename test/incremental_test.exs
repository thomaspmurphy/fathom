defmodule IncrementalTest do
  @moduledoc """
  End-to-end tests for `mix fathom.build --incremental`.

  The property worth testing is not that an update inserts rows, which any
  version of the code would do, but that it converges: after adding and then
  removing a module, the database has to hold exactly what a full build of the
  same source would have produced. Anything left behind is the staleness the
  feature exists to avoid.
  """

  use ExUnit.Case, async: false

  import Fathom.Fixture

  @probe """

  defmodule SampleApp.Probe do
    def ping, do: SampleApp.Accounts.purge_users()
  end
  """

  test "replaces recompiled modules, purges deleted ones, and converges on a full build" do
    in_sandbox(fn dir ->
      db = Path.join(dir, ".fathom/program.db")
      source = Path.join(dir, "lib/sample_app.ex")
      original = File.read!(source)

      build!(dir)
      baseline = table_counts(db)

      File.write!(source, original <> @probe)
      build!(dir, ["--incremental"])

      assert count(db, "FROM functions WHERE module = 'SampleApp.Probe'") == 1

      assert count(db, """
             FROM calls
             WHERE caller = 'SampleApp.Probe.ping/0'
               AND callee = 'SampleApp.Accounts.purge_users/0'
             """) == 1

      # `frameworks.ex` was not recompiled, so the rows it owns were never
      # deleted. If delete-by-module were scoped wrongly these would be gone.
      assert count(db, "FROM routes") == baseline.routes
      assert count(db, "FROM schemas") == baseline.schemas

      # A delete-and-reinsert loses the post-compile facts unless introspection
      # runs over the recompiled modules too.
      assert value(db, "SELECT doc FROM functions WHERE mfa = 'SampleApp.Accounts.create_user/1'") =~
               "Creates a user"

      File.write!(source, original)
      build!(dir, ["--incremental"])

      assert count(db, "FROM functions WHERE module = 'SampleApp.Probe'") == 0
      assert count(db, "FROM modules WHERE module = 'SampleApp.Probe'") == 0

      # The edge out of the deleted module goes with it; so does the one
      # pointing at it, which belongs to a module nothing recompiled.
      assert count(db, "FROM module_deps WHERE from_module = 'SampleApp.Probe'") == 0
      assert count(db, "FROM module_deps WHERE to_module = 'SampleApp.Probe'") == 0

      assert table_counts(db) == baseline
    end)
  end

  test "an incremental build with nothing to recompile changes nothing" do
    in_sandbox(fn dir ->
      db = Path.join(dir, ".fathom/program.db")

      build!(dir)
      before = table_counts(db)

      build!(dir, ["--incremental"])

      assert table_counts(db) == before
    end)
  end

  test "falls back to a full build when there is no database to update" do
    in_sandbox(fn dir ->
      db = Path.join(dir, ".fathom/program.db")

      build!(dir, ["--incremental"])

      assert File.exists?(db)
      assert count(db, "FROM functions") > 0
      assert count(db, "FROM routes") > 0
    end)
  end

  defp table_counts(db) do
    for {table, _cols} <- Fathom.Schema.tables(), table != :meta, into: %{} do
      {table, count(db, "FROM #{table}")}
    end
  end

  defp count(db, from), do: value(db, "SELECT count(*) #{from}")

  defp value(db, sql) do
    [[value]] = query_at(db, sql)
    value
  end
end
