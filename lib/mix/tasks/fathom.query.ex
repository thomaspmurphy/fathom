defmodule Mix.Tasks.Fathom.Query do
  @shortdoc "Runs a read-only query against the program database"

  @moduledoc """
  Queries the program database.

      mix fathom.query "SELECT mfa, file, line FROM functions WHERE name = 'create_user'"

  The connection is opened read-only, so a query that tries to modify the
  database fails at SQLite rather than being caught by inspecting the SQL. The
  database is a derived artefact in any case; the thing to change is the code.

  This exists so that a project needs nothing beyond `mix` to use Fathom. If
  `sqlite3` is installed, pointing it at `.fathom/program.db` works just as
  well and is usually what you want in a shell.

  ## Options

    * `--database`, `-d` - path to the database. Defaults to `.fathom/program.db`.
    * `--format`, `-f` - `table` (default), `tsv`, or `json`.
    * `--schema` - print the schema and exit, ignoring any query.
  """

  use Mix.Task

  alias Exqlite.Sqlite3
  alias Fathom.Schema

  @default_db ".fathom/program.db"

  @switches [database: :string, format: :string, schema: :boolean]
  @aliases [d: :database, f: :format]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    if opts[:schema] do
      Mix.shell().info(Schema.to_ddl())
    else
      sql = Enum.join(args, " ")
      if sql == "", do: Mix.raise("usage: mix fathom.query \"SELECT ...\"")

      opts
      |> Keyword.get(:database, @default_db)
      |> run_query(sql)
      |> render(Keyword.get(opts, :format, "table"))
      |> Mix.shell().info()
    end
  end

  defp run_query(path, sql) do
    unless File.exists?(path) do
      Mix.raise("no program database at #{path}. Run `mix fathom.build` first.")
    end

    {:ok, conn} = Sqlite3.open(path, mode: :readonly)

    try do
      case Sqlite3.prepare(conn, sql) do
        {:ok, stmt} ->
          {:ok, columns} = Sqlite3.columns(conn, stmt)
          {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
          :ok = Sqlite3.release(conn, stmt)
          {columns, rows}

        {:error, reason} ->
          Mix.raise("#{reason}")
      end
    after
      Sqlite3.close(conn)
    end
  end

  # -- rendering -------------------------------------------------------------

  defp render({columns, rows}, "json") do
    rows
    |> Enum.map(fn row -> columns |> Enum.zip(row) |> Map.new() end)
    |> inspect(pretty: true, limit: :infinity, printable_limit: :infinity)
  end

  defp render({columns, rows}, "tsv") do
    Enum.map_join([columns | Enum.map(rows, &cells/1)], "\n", &Enum.join(&1, "\t"))
  end

  defp render({_columns, []}, _format), do: "(no rows)"

  defp render({columns, rows}, _table) do
    cells = Enum.map(rows, &cells/1)
    widths = widths([columns | cells])

    header = pad_row(columns, widths)
    rule = Enum.map_join(widths, "-+-", &String.duplicate("-", &1))
    body = Enum.map_join(cells, "\n", &pad_row(&1, widths))

    "#{header}\n#{rule}\n#{body}\n\n(#{length(rows)} rows)"
  end

  defp widths(rows) do
    rows
    |> Enum.zip_with(& &1)
    |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)
  end

  defp pad_row(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join(" | ", fn {cell, width} -> String.pad_trailing(cell, width) end)
    |> String.trim_trailing()
  end

  defp cells(row), do: Enum.map(row, &cell/1)

  defp cell(nil), do: ""
  defp cell(value) when is_binary(value), do: String.replace(value, ~r/\s+/, " ")
  defp cell(value), do: to_string(value)
end
