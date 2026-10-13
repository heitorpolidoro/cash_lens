defmodule CashLens.Workers.RecalculateBalanceWorkerTest do
  use CashLens.DataCase, async: false
  use Oban.Testing, repo: CashLens.Repo
  alias CashLens.Accounting.Balance
  alias CashLens.Workers.RecalculateBalanceWorker
  import CashLens.AccountsFixtures
  import CashLens.AccountingFixtures

  defp user_id, do: CashLens.Repo.current_user_id()

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

    args = %{"user_id" => user_id(), "account_id" => account.id, "year" => 2026, "month" => 1}
    assert :ok = RecalculateBalanceWorker.perform(%Oban.Job{args: args})

    assert_enqueued(
      worker: RecalculateBalanceWorker,
      args: %{user_id: user_id(), account_id: account.id, year: 2026, month: 2}
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

    args = %{"user_id" => user_id(), "account_id" => account.id, "year" => 2026, "month" => 1}
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

    args = %{"user_id" => user_id(), "account_id" => account.id, "year" => 2026, "month" => 12}
    assert :ok = RecalculateBalanceWorker.perform(%Oban.Job{args: args})

    assert_enqueued(
      worker: RecalculateBalanceWorker,
      args: %{user_id: user_id(), account_id: account.id, year: 2027, month: 1}
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

    args = %{"user_id" => user_id(), "account_id" => account.id, "year" => 2026, "month" => 1}
    assert {:error, "enqueue failed"} = RecalculateBalanceWorker.perform(%Oban.Job{args: args})
  end

  test "perform/1 handles Accounting.calculate_monthly_balance failure" do
    # Use a valid but non-existent UUID
    args = %{
      "user_id" => user_id(),
      "account_id" => Ecto.UUID.generate(),
      "year" => 2026,
      "month" => 1
    }

    assert {:error, _} = RecalculateBalanceWorker.perform(%Oban.Job{args: args})
  end

  describe "tenancy" do
    alias CashLens.Tenancy

    test "perform/1 discards a job without user_id and writes nothing" do
      account = account_fixture()
      args = %{"account_id" => account.id, "year" => 2026, "month" => 1}

      assert {:discard, _} = RecalculateBalanceWorker.perform(%Oban.Job{args: args})
      assert CashLens.Repo.aggregate(Balance, :count) == 0
    end

    test "perform/1 discards a job for a user that no longer exists" do
      account = account_fixture()

      args = %{
        "user_id" => Ecto.UUID.generate(),
        "account_id" => account.id,
        "year" => 2026,
        "month" => 1
      }

      assert {:discard, _} = RecalculateBalanceWorker.perform(%Oban.Job{args: args})
      assert CashLens.Repo.aggregate(Balance, :count) == 0
    end

    test "a job for A never writes B's balances and chains A's user_id" do
      %{a: a, b: b} = cross_tenant()
      a_account = account_fixture(%{user: a})
      b_account = account_fixture(%{user: b})

      balance = fn user, account, month ->
        balance_fixture(%{user: user, account_id: account.id, year: 2026, month: month})
      end

      Tenancy.acting_as(a, fn ->
        balance.(a, a_account, 1)
        balance.(a, a_account, 2)
      end)

      b_balance = Tenancy.acting_as(b, fn -> balance.(b, b_account, 1) end)

      args = %{
        "user_id" => a.id,
        "account_id" => a_account.id,
        "year" => 2026,
        "month" => 1
      }

      assert :ok = RecalculateBalanceWorker.perform(%Oban.Job{args: args})

      assert_enqueued(
        worker: RecalculateBalanceWorker,
        args: %{user_id: a.id, account_id: a_account.id, year: 2026, month: 2}
      )

      Tenancy.acting_as(b, fn ->
        assert CashLens.Repo.get!(Balance, b_balance.id) == b_balance
      end)

      # A job naming B's account but run for A is :not_found and writes nothing.
      foreign = %{args | "account_id" => b_account.id}
      assert {:error, :not_found} = RecalculateBalanceWorker.perform(%Oban.Job{args: foreign})

      Tenancy.acting_as(b, fn ->
        assert CashLens.Repo.get!(Balance, b_balance.id) == b_balance
      end)
    end
  end
end
