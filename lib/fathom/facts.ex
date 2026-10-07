defmodule Fathom.Facts do
  @moduledoc """
  The in-memory fact buffer that the compiler tracer writes into.

  Tracers run concurrently inside the compiler's own processes, so this is a
  public ETS table rather than a process. Sending a message per traced event
  would serialise the whole compilation behind one mailbox.

  Facts are stored as `{partition_key, fact}` in a `:duplicate_bag`. The
  partition key is the module being compiled, which spreads writes across
  buckets instead of hammering a single key; nothing reads facts back by key,
  `Fathom.Store` folds over the whole table at dump time.
  """

  @table :fathom_facts

  @doc """
  Creates the fact table, replacing any table left over from a previous run.

  Returns `:ok`; the table is named, so the identifier is of no use to callers.
  """
  def init do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)

    _table =
      :ets.new(@table, [
        :named_table,
        :public,
        :duplicate_bag,
        write_concurrency: :auto,
        read_concurrency: false
      ])

    :ok
  end

  @doc """
  Records a fact under the given partition key. Called from compiler processes.

  Returns `:ok` rather than the `true` from `:ets.insert/2`, because the
  compiler requires every tracer callback to return `:ok` and the tracer
  clauses tail-call straight into this.
  """
  def put(partition, fact) do
    :ets.insert(@table, {partition, fact})
    :ok
  end

  @doc "Folds `fun` over every fact. Order is unspecified."
  def reduce(acc, fun), do: :ets.foldl(fn {_partition, fact}, a -> fun.(fact, a) end, acc, @table)

  @doc "Returns every fact as a list. Prefer `reduce/2` on large codebases."
  def to_list, do: reduce([], &[&1 | &2])

  @doc "Number of facts currently buffered."
  def count, do: :ets.info(@table, :size)

  @doc """
  The distinct partition keys, i.e. every module that has produced a fact.

  During an incremental build this is how the compiler's choice of what to
  recompile is read back out. Call it before any post-compile pass starts
  buffering facts of its own, or those modules will be in the answer too.
  """
  def partitions do
    Stream.unfold(:ets.first(@table), fn
      :"$end_of_table" -> nil
      module -> {module, :ets.next(@table, module)}
    end)
    |> Enum.to_list()
  end

  @doc "Whether the table exists, i.e. whether a build is in progress."
  def started?, do: :ets.whereis(@table) != :undefined

  @doc "Drops the table."
  def destroy do
    if started?(), do: :ets.delete(@table)
    :ok
  end
end
