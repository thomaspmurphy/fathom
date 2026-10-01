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
  def build! do
    {output, status} =
      System.cmd("mix", ["fathom.build", "--quiet"],
        cd: @app_dir,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}]
      )

    if status != 0 do
      raise "fathom.build failed in the fixture app:\n\n#{output}"
    end

    :ok
  end

  @doc "Runs a query and returns rows as lists."
  def query(sql, args \\ []) do
    {:ok, conn} = Sqlite3.open(@db_path, mode: :readonly)

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
