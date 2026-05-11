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
      assert Accounting.list_balances() != []
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

      assert Accounting.list_balances(%{"month" => "1"}) != []
      assert Accounting.list_balances(%{"month" => "10"}) == []
      assert Accounting.list_balances(%{"year" => "2026"}) != []
      assert length(Accounting.list_balances(%{"account_id" => acc.id})) == 3

      assert length(
               Accounting.list_balances(%{"account_id" => nil, "month" => nil, "year" => ""})
             ) >= 3

      assert length(Accounting.list_balances(%{"account_id" => "", "month" => "", "year" => nil})) >=
               3
    end

    test "get_latest_balance_for_account/1 returns the most recent balance" do
      acc = account_fixture()
      Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      Accounting.calculate_monthly_balance(acc.id, 2026, 2)

      latest = Accounting.get_latest_balance_for_account(acc.id)
      assert latest.month == 2
    end

    test "list_latest_balances/0 returns latest for each account" do
      acc1 = account_fixture()
      acc2 = account_fixture()
      Accounting.calculate_monthly_balance(acc1.id, 2026, 1)
      Accounting.calculate_monthly_balance(acc1.id, 2026, 2)
      Accounting.calculate_monthly_balance(acc2.id, 2026, 1)

      latest_list = Accounting.list_latest_balances()
      assert [_, _ | _] = latest_list
    end

    test "get_historical_balances/0 returns aggregated data" do
      acc = account_fixture()
      Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      history = Accounting.get_historical_balances()
      assert history != []
      entry = Enum.find(history, &(&1.month == 1 and &1.year == 2026))
      assert entry.month == 1
    end

    test "recalculate_all_balances/0 runs through all balances" do
      acc = account_fixture()
      Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert Accounting.recalculate_all_balances() == :ok
    end

    test "calculate_monthly_balance preserves initial_balance when recalculating root" do
      acc = account_fixture(balance: "500")
      {:ok, b} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)

      # Manually update initial_balance to something different than auto-calculated
      {:ok, b} = Accounting.update_balance(b, %{initial_balance: "1000"})

      # Recalculate - it should preserve the 1000 if it detects it as root (no prev balance)
      {:ok, updated} = Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      assert Decimal.equal?(updated.initial_balance, "1000")
      assert updated.id == b.id
    end

    test "calculate_monthly_balance chains from latest snapshot across years" do
      account = account_fixture(balance: "1000")

      # Create a snapshot in Dec 2025
      {:ok, snapshot} = Accounting.calculate_monthly_balance(account.id, 2025, 12)
      # Manually mark as snapshot
      {:ok, _snapshot} = Accounting.update_balance(snapshot, %{is_snapshot: true})

      # Calculate Feb 2026. Should find Dec 2025 snapshot and recurse.
      {:ok, balance} = Accounting.calculate_monthly_balance(account.id, 2026, 2)
      assert balance.year == 2026
      assert balance.month == 2
      assert Repo.get_by(Balance, account_id: account.id, year: 2026, month: 1)
      assert Repo.get_by(Balance, account_id: account.id, year: 2025, month: 12)
    end

    test "calculate_monthly_balance with huge gap" do
      account = account_fixture(balance: "0")
      Accounting.calculate_monthly_balance(account.id, 2025, 1)

      # Gap of 11 months
      {:ok, balance} = Accounting.calculate_monthly_balance(account.id, 2026, 1)
      assert balance.year == 2026
      assert balance.month == 1
      # It should have filled the gap
      assert Repo.get_by(Balance, account_id: account.id, year: 2025, month: 6)
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

  describe "rebuild_account_balances/1" do
    test "is a no-op when the account has no transactions" do
      acc = account_fixture(balance: "500")

      assert :ok = Accounting.rebuild_account_balances(acc.id)
      assert Repo.all(from b in Balance, where: b.account_id == ^acc.id) == []
    end

    test "deletes existing balances and rebuilds them with the new initial balance" do
      acc = account_fixture(balance: "100")

      transaction_fixture(%{account_id: acc.id, date: ~D[2026-01-15], amount: "50"})

      Accounting.calculate_monthly_balance(acc.id, 2026, 1)

      original = Repo.one!(from b in Balance, where: b.account_id == ^acc.id and b.month == 1)
      assert Decimal.equal?(original.initial_balance, "100")

      {:ok, updated_acc} = CashLens.Accounts.update_account(acc, %{balance: "200"})

      assert :ok = Accounting.rebuild_account_balances(updated_acc.id)

      rebuilt = Repo.one!(from b in Balance, where: b.account_id == ^acc.id and b.month == 1)
      assert Decimal.equal?(rebuilt.initial_balance, "200")
    end

    test "chain propagates correctly across multiple months" do
      acc = account_fixture(balance: "1000")

      transaction_fixture(%{account_id: acc.id, date: ~D[2026-01-10], amount: "100"})
      transaction_fixture(%{account_id: acc.id, date: ~D[2026-02-10], amount: "200"})
      transaction_fixture(%{account_id: acc.id, date: ~D[2026-03-10], amount: "-50"})

      Accounting.calculate_monthly_balance(acc.id, 2026, 1)
      Accounting.calculate_monthly_balance(acc.id, 2026, 2)
      Accounting.calculate_monthly_balance(acc.id, 2026, 3)

      {:ok, updated_acc} = CashLens.Accounts.update_account(acc, %{balance: "500"})

      assert :ok = Accounting.rebuild_account_balances(updated_acc.id)

      jan = Repo.one!(from b in Balance, where: b.account_id == ^acc.id and b.month == 1)
      feb = Repo.one!(from b in Balance, where: b.account_id == ^acc.id and b.month == 2)
      mar = Repo.one!(from b in Balance, where: b.account_id == ^acc.id and b.month == 3)

      assert Decimal.equal?(jan.initial_balance, "500")
      assert Decimal.equal?(feb.initial_balance, jan.final_balance)
      assert Decimal.equal?(mar.initial_balance, feb.final_balance)
    end
  end

  describe "coverage" do
    test "list_balances with empty string filters" do
      account = account_fixture()
      Accounting.calculate_monthly_balance(account.id, 2026, 1)

      filters = %{"account_id" => "", "month" => "", "year" => ""}
      balances = Accounting.list_balances(filters)
      assert balances != []
    end

    test "calculate_monthly_balance triggers get_previous_period year transition" do
      account = account_fixture()
      # Ensure Jan 2026 is calculated based on Dec 2025
      Accounting.calculate_monthly_balance(account.id, 2025, 12)
      {:ok, balance} = Accounting.calculate_monthly_balance(account.id, 2026, 1)
      assert balance.year == 2026
      assert balance.month == 1
    end

    test "calculate_from_point handles failure fallback" do
      account = account_fixture()
      {:ok, b1} = Accounting.calculate_monthly_balance(account.id, 2026, 1)

      invalid_uuid = Ecto.UUID.generate()
      # Pass invalid_uuid to force calculate_monthly_balance inside calculate_from_point to fail
      # This handles the {:error, _} branch without mocking or mutating global Logger state.
      result = Accounting.__test_calculate_from_point(invalid_uuid, b1, 2026, 2)
      assert result == b1.final_balance
    end
  end
end
