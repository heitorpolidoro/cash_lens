defmodule CashLens.Workers.RecalculateBalanceWorkerTest do
  use CashLens.DataCase, async: false
  use Oban.Testing, repo: CashLens.Repo
  alias CashLens.Workers.RecalculateBalanceWorker
  alias CashLens.Accounting.Balance
  import CashLens.AccountsFixtures

  test "perform/1 calculates balance and enqueues next month if it exists" do
    account = account_fixture()
    # Create current month balance
    CashLens.Repo.insert!(%Balance{
      account_id: account.id,
      year: 2026,
      month: 1,
      initial_balance: Decimal.new("0"),
      final_balance: Decimal.new("0"),
      income: Decimal.new("0"),
      expenses: Decimal.new("0"),
      balance: Decimal.new("0")
    })

    # Create next month balance to trigger enqueueing
    CashLens.Repo.insert!(%Balance{
      account_id: account.id,
      year: 2026,
      month: 2,
      initial_balance: Decimal.new("0"),
      final_balance: Decimal.new("0"),
      income: Decimal.new("0"),
      expenses: Decimal.new("0"),
      balance: Decimal.new("0")
    })

    args = %{"account_id" => account.id, "year" => 2026, "month" => 1}
    assert :ok = RecalculateBalanceWorker.perform(%Oban.Job{args: args})

    assert_enqueued(
      worker: RecalculateBalanceWorker,
      args: %{account_id: account.id, year: 2026, month: 2}
    )
  end

  test "perform/1 calculates balance and stops if next month does not exist" do
    account = account_fixture()

    CashLens.Repo.insert!(%Balance{
      account_id: account.id,
      year: 2026,
      month: 1,
      initial_balance: Decimal.new("0"),
      final_balance: Decimal.new("0"),
      income: Decimal.new("0"),
      expenses: Decimal.new("0"),
      balance: Decimal.new("0")
    })

    args = %{"account_id" => account.id, "year" => 2026, "month" => 1}
    assert :ok = RecalculateBalanceWorker.perform(%Oban.Job{args: args})
    refute_enqueued(worker: RecalculateBalanceWorker)
  end

  test "perform/1 handles December transition" do
    account = account_fixture()

    CashLens.Repo.insert!(%Balance{
      account_id: account.id,
      year: 2026,
      month: 12,
      initial_balance: Decimal.new("0"),
      final_balance: Decimal.new("0"),
      income: Decimal.new("0"),
      expenses: Decimal.new("0"),
      balance: Decimal.new("0")
    })

    CashLens.Repo.insert!(%Balance{
      account_id: account.id,
      year: 2027,
      month: 1,
      initial_balance: Decimal.new("0"),
      final_balance: Decimal.new("0"),
      income: Decimal.new("0"),
      expenses: Decimal.new("0"),
      balance: Decimal.new("0")
    })

    args = %{"account_id" => account.id, "year" => 2026, "month" => 12}
    assert :ok = RecalculateBalanceWorker.perform(%Oban.Job{args: args})

    assert_enqueued(
      worker: RecalculateBalanceWorker,
      args: %{account_id: account.id, year: 2027, month: 1}
    )
  end

  defmodule MockObanError do
    def insert(_job), do: {:error, "enqueue failed"}
  end

  test "perform/1 handles Oban.insert failure" do
    account = account_fixture()

    CashLens.Repo.insert!(%Balance{
      account_id: account.id,
      year: 2026,
      month: 1,
      initial_balance: Decimal.new("0"),
      final_balance: Decimal.new("0"),
      income: Decimal.new("0"),
      expenses: Decimal.new("0"),
      balance: Decimal.new("0")
    })

    CashLens.Repo.insert!(%Balance{
      account_id: account.id,
      year: 2026,
      month: 2,
      initial_balance: Decimal.new("0"),
      final_balance: Decimal.new("0"),
      income: Decimal.new("0"),
      expenses: Decimal.new("0"),
      balance: Decimal.new("0")
    })

    Application.put_env(:cash_lens, :oban_module, MockObanError)
    on_exit(fn -> Application.delete_env(:cash_lens, :oban_module) end)

    args = %{"account_id" => account.id, "year" => 2026, "month" => 1}
    assert {:error, "enqueue failed"} = RecalculateBalanceWorker.perform(%Oban.Job{args: args})
  end

  test "perform/1 handles Accounting.calculate_monthly_balance failure" do
    # Use a valid but non-existent UUID
    args = %{"account_id" => Ecto.UUID.generate(), "year" => 2026, "month" => 1}
    assert {:error, _} = RecalculateBalanceWorker.perform(%Oban.Job{args: args})
  end
end
