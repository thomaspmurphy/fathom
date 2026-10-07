defmodule Fathom.Fixture do
  @moduledoc """
  Builds the sample application's program database and queries it.

  The build runs as a subprocess rather than in-process because a tracer can
  only observe a compilation it was attached to from the start, and the test
  suite's own compilation is long over by the time a test runs.
  """

  alias Exqlite.Sqlite3

  @app_dir Path.expand("../../fixtures/sample_app", __DIR__)
  @db_path Path.join(@app_dir, ".fathom/program.db")

  def app_dir, do: @app_dir
  def db_path, do: @db_path

  @doc "Compiles the sample app under the tracer and writes its database."
  def build!(dir \\ @app_dir, args \\ []) do
    {output, status} =
      System.cmd("mix", ["fathom.build", "--quiet" | args],
        cd: dir,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}]
      )

    if status != 0 do
      raise "fathom.build failed in #{dir}:\n\n#{output}"
    end

    :ok
  end

  @doc """
  Copies the sample app to a temporary directory and calls `fun` with its path.

  An incremental build can only be tested by changing source between two
  builds. Editing `fixtures/sample_app` in place would leave the checkout
  dirty whenever a test failed before it could put the file back, so the edits
  go to a throwaway copy instead.
  """
  def in_sandbox(fun) do
    dir = Path.join(System.tmp_dir!(), "fathom-sandbox-#{System.unique_integer([:positive])}")

    try do
      File.cp_r!(@app_dir, dir)
      File.rm_rf!(Path.join(dir, ".fathom"))
      repoint_fathom(dir)
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end

  # The fixture depends on Fathom through a relative path, which stops
  # resolving the moment the copy leaves the repository.
  defp repoint_fathom(dir) do
    mix_exs = Path.join(dir, "mix.exs")
    root = Path.expand("../..", @app_dir)

    File.write!(
      mix_exs,
      String.replace(File.read!(mix_exs), ~s(path: "../.."), ~s(path: "#{root}"))
    )
  end

  @doc "Runs a query and returns rows as lists."
  def query(sql, args \\ []), do: query_at(@db_path, sql, args)

  @doc "Runs a query against a database somewhere other than the fixture's own."
  def query_at(db_path, sql, args \\ []) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readonly)

    try do
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      :ok = Sqlite3.bind(stmt, args)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      Sqlite3.release(conn, stmt)
      rows
    after
      Sqlite3.close(conn)
    end
  end

  @doc "Runs a query expected to return a single column, and flattens it."
  def column(sql, args \\ []), do: sql |> query(args) |> Enum.map(&hd/1)

  @doc "Runs a query expected to return exactly one value."
  def one(sql, args \\ []) do
    case query(sql, args) do
      [[value]] -> value
      [] -> nil
      other -> raise "expected a single value, got: #{inspect(other)}"
    end
  end
end
