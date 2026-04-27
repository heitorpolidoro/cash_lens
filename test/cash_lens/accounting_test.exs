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

    test "fallbacks to snapshot when previous month is missing" do
      acc = account_fixture(%{balance: "100.00"})

      # Create a snapshot in Jan
      {:ok, _} =
        Accounting.create_balance(%{
          account_id: acc.id,
          year: 2026,
          month: 1,
          initial_balance: "100.00",
          income: "0",
          expenses: "0",
          balance: "0",
          final_balance: "100.00",
          is_snapshot: true
        })

      # Now calculate Mar (Feb is missing)
      # It should find snapshot in Jan and calculate Feb then Mar
      {:ok, b3} = Accounting.calculate_monthly_balance(acc.id, 2026, 3)
      assert b3.month == 3
      assert b3.initial_balance == Decimal.new("100.00")

      # Verify Feb was also created
      assert Repo.get_by(Balance, account_id: acc.id, year: 2026, month: 2)
    end

    test "is_snapshot is true for months multiple of 6" do
      acc = account_fixture()
      {:ok, b6} = Accounting.calculate_monthly_balance(acc.id, 2026, 6)
      assert b6.is_snapshot == true

      {:ok, b1} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert b1.is_snapshot == false
    end
  end

  describe "queries and filters" do
    test "list_latest_balances/0 returns most recent balance per account" do
      acc1 = account_fixture()
      acc2 = account_fixture()

      Accounting.calculate_monthly_balance(acc1.id, 2026, 1)
      Accounting.calculate_monthly_balance(acc1.id, 2026, 2)
      Accounting.calculate_monthly_balance(acc2.id, 2026, 1)

      latest = Accounting.list_latest_balances()
      assert length(latest) == 2

      b1 = Enum.find(latest, &(&1.account_id == acc1.id))
      assert b1.month == 2

      b2 = Enum.find(latest, &(&1.account_id == acc2.id))
      assert b2.month == 1
    end

    test "get_historical_balances/0 aggregates by month" do
      acc1 = account_fixture()
      acc2 = account_fixture()

      Accounting.calculate_monthly_balance(acc1.id, 2026, 1)
      Accounting.calculate_monthly_balance(acc2.id, 2026, 1)

      history = Accounting.get_historical_balances()
      assert length(history) >= 1
      assert Enum.any?(history, &(&1.month == 1))
    end

    test "get_oldest_balance_for_account/1" do
      acc = account_fixture()
      Accounting.calculate_monthly_balance(acc.id, 2026, 2)
      Accounting.calculate_monthly_balance(acc.id, 2026, 1)

      oldest = Accounting.get_oldest_balance_for_account(acc.id)
      assert oldest.month == 1
    end

    test "list_balances/1 with filters and pagination" do
      acc = account_fixture()
      Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      Accounting.calculate_monthly_balance(acc.id, 2026, 2)
      Accounting.calculate_monthly_balance(acc.id, 2026, 3)

      assert length(Accounting.list_balances(%{"account_id" => acc.id}, 1, 2)) == 2
      assert length(Accounting.list_balances(%{"account_id" => acc.id}, 2, 2)) == 1

      assert length(Accounting.list_balances(%{"month" => "1"})) >= 1
      assert length(Accounting.list_balances(%{"month" => "10"})) == 0
      assert length(Accounting.list_balances(%{"year" => "2026"})) >= 1
      assert length(Accounting.list_balances(%{"account_id" => acc.id})) == 3

      assert length(
               Accounting.list_balances(%{"account_id" => nil, "month" => nil, "year" => ""})
             ) >= 3
    end

    test "calculate_monthly_balance chains from latest snapshot" do
      account = account_fixture(balance: "1000")

      # Create a snapshot in month 6
      {:ok, snapshot} = Accounting.calculate_monthly_balance(account.id, 2026, 6)
      assert snapshot.is_snapshot

      # Delete month 6 to simulate it being the anchor, and we want to calculate month 8
      # Actually, the logic finds the latest snapshot BEFORE the target month.
      # If we calculate month 8, it should find snapshot at month 6.

      {:ok, balance8} = Accounting.calculate_monthly_balance(account.id, 2026, 8)
      # Month 8 depends on 7, 7 depends on 6 (snapshot).
      # The code should recursively calculate 7 then 8.
      assert balance8.month == 8
      assert Repo.get_by(Balance, account_id: account.id, year: 2026, month: 7)
    end

    test "get_oldest_balance_for_account/1 returns the oldest record" do
      acc = account_fixture()
      Accounting.calculate_monthly_balance(acc.id, 2026, 3)
      Accounting.calculate_monthly_balance(acc.id, 2026, 1)

      oldest = Accounting.get_oldest_balance_for_account(acc.id)
      assert oldest.month == 1
    end

    test "calculates monthly balance with January transition" do
      acc = account_fixture()
      # Calculating month 1 of 2026
      # This will call get_previous_period(2026, 1) -> {2025, 12}
      # and handle_initial_balance_fallback(acc.id, 2026, 1)
      assert {:ok, b} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert b.month == 1
      assert b.year == 2026

      # Recalculate existing balance
      assert {:ok, updated_b} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert updated_b.id == b.id
    end
  end

  describe "crud" do
    test "get_balance!/1" do
      acc = account_fixture()
      {:ok, b} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert Accounting.get_balance!(b.id).id == b.id
    end

    test "update_balance/2" do
      acc = account_fixture()
      {:ok, b} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert {:ok, updated} = Accounting.update_balance(b, %{income: "999.00"})
      assert updated.income == Decimal.new("999.00")
    end

    test "change_balance/2" do
      acc = account_fixture()
      {:ok, b} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      changeset = Accounting.change_balance(b, %{income: "888.00"})
      assert changeset.valid?
    end

    test "delete_balance/1" do
      acc = account_fixture()
      {:ok, b} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert {:ok, _} = Accounting.delete_balance(b)
      assert_raise Ecto.NoResultsError, fn -> Accounting.get_balance!(b.id) end
    end
  end
end
