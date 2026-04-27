defmodule CashLens.AccountingTest do
  use CashLens.DataCase, async: false

  alias CashLens.Accounting
  alias CashLens.Accounting.Balance
  import CashLens.AccountsFixtures
  import CashLens.TransactionsFixtures

  describe "balances" do
    test "list_balances/1 returns all balances" do
      acc = account_fixture()
      Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert length(Accounting.list_balances()) >= 1
    end

    test "calculate_monthly_balance/3 creates a balance" do
      acc = account_fixture()
      assert {:ok, %Balance{} = balance} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert balance.year == 2026
      assert balance.month == 1
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

      {:ok, balance8} = Accounting.calculate_monthly_balance(account.id, 2026, 8)
      # Month 8 depends on 7, 7 depends on 6 (snapshot).
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
      assert {:ok, updated} = Accounting.update_balance(b, %{income: "99.99"})
      assert updated.income == Decimal.new("99.99")
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
