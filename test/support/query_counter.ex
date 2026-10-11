defmodule CashLens.QueryCounter do
  @moduledoc """
  Counts the database queries a block of code issues, in total and per source
  table.

  Built on the `[:cash_lens, :repo, :query]` telemetry event Ecto emits for
  every query. Three properties are deliberate, because the naive version of
  each is wrong in a way that only shows up intermittently:

  * **Only the collecting process is counted.** `:telemetry.execute/3` runs
    every attached handler in the process that emitted the event, so `self()`
    inside the handler *is* the process that ran the query. Comparing it to the
    collecting process keeps a concurrently running async test — which shares
    the handler, since telemetry handlers are global — out of the tally. A
    budget asserted on a count inflated by somebody else's queries is flaky by
    construction. The module using this still belongs in `async: false`: the
    filter protects the count, not the database.

  * **Events with a `nil` `:source` are skipped.** The sandbox's own `begin`,
    `commit`, `rollback` and `savepoint` statements, and any raw
    `Repo.query/2`, carry no source. They are an artifact of the test
    transaction, not work the code under test asked for, and their number
    depends on how the sandbox was set up.

  * **The handler is detached even when the block raises.** Otherwise one
    failing test leaves a handler attached that goes on counting into every
    test that follows it, in the process that happens to be running.

  ## Example

      {conn, counts} = QueryCounter.count(fn -> get(conn, ~p"/") end)

      assert counts.total <= 200
      assert counts.by_table["transactions"] <= 30
  """

  @event [:cash_lens, :repo, :query]

  @typedoc """
  The tally of a counted block: `total` is the number of counted events, and
  `by_table` maps each source table to its own share. The two always agree,
  because `total` is the sum of `by_table` — an event that is not attributed to
  a table is not counted at all.
  """
  @type counts :: %{total: non_neg_integer(), by_table: %{String.t() => non_neg_integer()}}

  @doc """
  Runs `fun`, returning `{fun's result, counts}`.
  """
  @spec count((-> result)) :: {result, counts()} when result: term()
  def count(fun) when is_function(fun, 0) do
    owner = self()
    tally = :ets.new(:query_counter, [:set, :public])
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      @event,
      &__MODULE__.handle_event/4,
      %{owner: owner, tally: tally}
    )

    try do
      result = fun.()
      {result, read(tally)}
    after
      :telemetry.detach(handler_id)
      :ets.delete(tally)
    end
  end

  @doc """
  How many queries `counts` attributes to `table`, zero when it holds none.

  A table the block never reached is simply absent from the tally, so a
  `>= 1` assertion written against this function fails on the absent key rather
  than passing vacuously against a missing one.
  """
  @spec for_table(counts(), String.t()) :: non_neg_integer()
  def for_table(%{by_table: by_table}, table), do: Map.get(by_table, table, 0)

  @doc false
  def handle_event(_event, _measurements, metadata, %{owner: owner, tally: tally}) do
    if self() == owner, do: tally(tally, Map.get(metadata, :source))

    :ok
  end

  defp tally(_tally, nil), do: :ok

  defp tally(tally, source) when is_binary(source) do
    :ets.update_counter(tally, source, {2, 1}, {source, 0})

    :ok
  end

  defp read(tally) do
    by_table = tally |> :ets.tab2list() |> Map.new()

    %{total: by_table |> Map.values() |> Enum.sum(), by_table: by_table}
  end
end
