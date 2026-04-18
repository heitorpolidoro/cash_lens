defmodule CashLens.AccountingTest do
  use CashLens.DataCase, async: true
  alias CashLens.Accounting
  alias CashLens.Accounting.Balance
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  describe "calculate_monthly_balance/3" do
    test "correctly chains balances between months" do
      acc = account_fixture(%{name: "Checking", balance: "1000.00"})

      # Month 1: Jan 2026
      # Initial: 1000.00 (from account)
      # Transactions: -100.00
      # Final should be: 900.00
      transaction_fixture(%{account_id: acc.id, date: ~D[2026-01-15], amount: "-100.00"})
      {:ok, b1} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert b1.initial_balance == Decimal.new("1000.00")
      assert b1.final_balance == Decimal.new("900.00")

      # Month 2: Feb 2026
      # Initial: 900.00 (chained from Jan)
      # Transactions: +50.00
      # Final should be: 950.00
      transaction_fixture(%{account_id: acc.id, date: ~D[2026-02-10], amount: "50.00"})
      {:ok, b2} = Accounting.calculate_monthly_balance(acc.id, 2026, 2)
      assert b2.initial_balance == Decimal.new("900.00")
      assert b2.final_balance == Decimal.new("950.00")
    end

    test "recalculates correctly when middle month changes" do
      acc = account_fixture(%{name: "Savings", balance: "0"})

      # Jan: +100 -> Final 100
      transaction_fixture(%{account_id: acc.id, date: ~D[2026-01-01], amount: "100.00"})
      Accounting.calculate_monthly_balance(acc.id, 2026, 1)

      # Feb: +50 -> Final 150
      transaction_fixture(%{account_id: acc.id, date: ~D[2026-02-01], amount: "50.00"})
      Accounting.calculate_monthly_balance(acc.id, 2026, 2)

      # Now add a new transaction in Jan (+20)
      transaction_fixture(%{account_id: acc.id, date: ~D[2026-01-15], amount: "20.00"})

      # Run recalculation
      :ok = Accounting.recalculate_all_balances()

      # Verify Jan
      b1 = Repo.get_by(Balance, account_id: acc.id, year: 2026, month: 1)
      assert b1.final_balance == Decimal.new("120.00")

      # Verify Feb (Chained)
      b2 = Repo.get_by(Balance, account_id: acc.id, year: 2026, month: 2)
      assert b2.initial_balance == Decimal.new("120.00")
      assert b2.final_balance == Decimal.new("170.00")
    end
  end
end
