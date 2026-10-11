defmodule CashLens.QueryCounterTest do
  @moduledoc """
  The three properties `CashLens.QueryCounter` exists to have. Each one is the
  reason a dashboard budget asserted with the naive counter would be flaky or
  vacuous, so each is checked here rather than left to the budget test, where a
  wrong count looks like a regression in the dashboard.
  """
  # Not async: the process-isolation test below runs a query from a second
  # process, which needs the shared sandbox.
  use CashLens.DataCase, async: false

  alias CashLens.Accounts.Account
  alias CashLens.QueryCounter
  alias CashLens.Transactions.Transaction

  @event [:cash_lens, :repo, :query]

  test "tallies queries by source table and totals them" do
    {:counted, counts} =
      QueryCounter.count(fn ->
        Repo.aggregate(Account, :count)
        Repo.aggregate(Transaction, :count)
        Repo.aggregate(Transaction, :count)
        :counted
      end)

    assert QueryCounter.for_table(counts, "accounts") == 1
    assert QueryCounter.for_table(counts, "transactions") == 2
    assert counts.total == 3
  end

  test "for_table/2 reports zero for a table the block never reached" do
    {:nothing_ran, counts} = QueryCounter.count(fn -> :nothing_ran end)

    assert QueryCounter.for_table(counts, "transactions") == 0
    assert counts.total == 0
  end

  test "skips events whose source is nil" do
    {_result, counts} =
      QueryCounter.count(fn ->
        # A raw statement has no source, exactly like the sandbox's own
        # begin/commit/rollback traffic.
        Repo.query!("SELECT 1")
      end)

    assert counts.by_table == %{}
    assert counts.total == 0
  end

  test "counts only the collecting process" do
    {_result, counts} =
      QueryCounter.count(fn ->
        Repo.aggregate(Account, :count)

        Task.async(fn -> Repo.aggregate(Transaction, :count) end) |> Task.await()
      end)

    assert QueryCounter.for_table(counts, "accounts") == 1
    assert QueryCounter.for_table(counts, "transactions") == 0
    assert counts.total == 1
  end

  test "detaches its handler when the block raises" do
    before = handler_ids()

    assert_raise RuntimeError, "boom", fn ->
      QueryCounter.count(fn -> raise "boom" end)
    end

    assert handler_ids() == before
  end

  defp handler_ids do
    @event |> :telemetry.list_handlers() |> Enum.map(& &1.id) |> Enum.sort()
  end
end
