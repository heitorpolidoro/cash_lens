defmodule CashLens.TransactionsTest do
  use CashLens.DataCase, async: false

  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction
  alias CashLens.AccountsFixtures

  import CashLens.TransactionsFixtures

  setup do
    # Clear global patterns to avoid CI collisions
    Repo.delete_all(CashLens.Transactions.BulkIgnorePattern)
    :ok
  end

  describe "list_transactions/1" do
    test "filters by search (description)" do
      transaction_fixture(%{description: "Supermarket shopping"})
      t2 = transaction_fixture(%{description: "Pharmacy bill"})

      results = Transactions.list_transactions(%{"search" => "pharmacy"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t2.id
    end

    test "filters by exact amount" do
      t1 = transaction_fixture(%{amount: "100.50"})
      _t2 = transaction_fixture(%{amount: "200.00"})

      results = Transactions.list_transactions(%{"amount" => "100.50"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t1.id
    end

    test "filters by type (debit/credit)" do
      t1 = transaction_fixture(%{amount: "-50.00"})
      t2 = transaction_fixture(%{amount: "150.00"})

      results = Transactions.list_transactions(%{"type" => "debit"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))

      results = Transactions.list_transactions(%{"type" => "credit"})
      assert Enum.any?(results, &(&1.id == t2.id))
      refute Enum.any?(results, &(&1.id == t1.id))
    end

    test "filters by amount range" do
      t1 = transaction_fixture(%{amount: "50.00"})
      t2 = transaction_fixture(%{amount: "150.00"})
      t3 = transaction_fixture(%{amount: "250.00"})

      results = Transactions.list_transactions(%{"amount_min" => 100, "amount_max" => 200})
      assert Enum.any?(results, &(&1.id == t2.id))
      refute Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t3.id))
    end

    test "filters by reimbursement status" do
      t1 = transaction_fixture(%{reimbursement_status: "pending"})
      t2 = transaction_fixture(%{reimbursement_status: "completed"})

      results = Transactions.list_transactions(%{"reimbursement_status" => "pending"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "filters by category nil" do
      t1 = transaction_fixture(%{category_id: nil})
      category = CashLens.CategoriesFixtures.category_fixture()
      t2 = transaction_fixture(%{category_id: category.id})

      results = Transactions.list_transactions(%{"category_id" => "nil"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "filters by account" do
      account = AccountsFixtures.account_fixture()
      t1 = transaction_fixture(%{account_id: account.id})
      t2 = transaction_fixture()

      results = Transactions.list_transactions(%{"account_id" => account.id})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "filters by date" do
      t1 = transaction_fixture(%{date: ~D[2026-01-01]})
      t2 = transaction_fixture(%{date: ~D[2026-01-02]})

      results = Transactions.list_transactions(%{"date" => ~D[2026-01-01]})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end

    test "sorts by date asc" do
      t1 = transaction_fixture(%{date: ~D[2026-01-01]})
      t2 = transaction_fixture(%{date: ~D[2026-01-02]})

      results = Transactions.list_transactions(%{"sort_order" => "asc"})
      # t1 should come before t2 in asc order
      idx1 = Enum.find_index(results, &(&1.id == t1.id))
      idx2 = Enum.find_index(results, &(&1.id == t2.id))
      assert idx1 < idx2
    end

    test "filters by month and year" do
      t1 = transaction_fixture(%{date: ~D[2026-01-15]})
      t2 = transaction_fixture(%{date: ~D[2026-02-15]})

      results = Transactions.list_transactions(%{"month" => "1", "year" => "2026"})
      assert Enum.any?(results, &(&1.id == t1.id))
      refute Enum.any?(results, &(&1.id == t2.id))
    end
  end

  describe "summaries" do
    test "get_monthly_summary/2 returns correct totals" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "100.00", date: ~D[2026-03-10], category_id: category.id})
      transaction_fixture(%{amount: "-40.00", date: ~D[2026-03-15], category_id: category.id})

      summary = Transactions.get_monthly_summary(~D[2026-03-01])
      assert summary.income == Decimal.new("100.00")
      assert summary.expenses == Decimal.new("40.00")
      assert summary.month == ~D[2026-03-01]
    end

    test "get_monthly_summary/2 with filter overrides" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "100.00", date: ~D[2026-03-10], category_id: category.id})

      summary = Transactions.get_monthly_summary(nil, %{"month" => "3", "year" => "2026"})
      assert summary.income == Decimal.new("100.00")
    end

    test "get_historical_summary/0" do
      category = CashLens.CategoriesFixtures.category_fixture(%{slug: "food"})
      transaction_fixture(%{amount: "100.00", date: ~D[2026-01-10], category_id: category.id})
      transaction_fixture(%{amount: "-50.00", date: ~D[2026-01-20], category_id: category.id})

      results = Transactions.get_historical_summary()

      assert Enum.any?(results, fn r ->
               r.month == 1 && r.year == 2026 && r.income == Decimal.new("100.00")
             end)
    end

    test "get_historical_category_summary/0" do
      category = CashLens.CategoriesFixtures.category_fixture(%{name: "Food", slug: "food"})
      transaction_fixture(%{amount: "-30.00", date: ~D[2026-01-10], category_id: category.id})

      results = Transactions.get_historical_category_summary()
      assert length(results) > 0
    end
  end

  describe "additional operations" do
    test "list_recent_transactions/1" do
      transaction_fixture()
      assert length(Transactions.list_recent_transactions(1)) == 1
    end

    test "reapply_auto_categorization/0" do
      # This is hard to test without specific rules, but we can at least call it
      assert Transactions.reapply_auto_categorization() == :ok
    end

    test "update_transaction_category/2" do
      t = transaction_fixture()
      c = CashLens.CategoriesFixtures.category_fixture()
      assert {:ok, updated} = Transactions.update_transaction_category(t.id, c.id)
      assert updated.category_id == c.id
    end

    test "unlink_reimbursement_by_key/1 handles nil" do
      assert Transactions.unlink_reimbursement_by_key(nil) == :ok
    end

    test "unlink_reimbursement_by_key/1 unlinks transactions" do
      key = Ecto.UUID.generate()

      t1 =
        transaction_fixture(%{
          amount: "-50.00",
          reimbursement_link_key: key,
          reimbursement_status: "completed"
        })

      t2 =
        transaction_fixture(%{
          amount: "50.00",
          reimbursement_link_key: key,
          reimbursement_status: "completed"
        })

      assert Transactions.unlink_reimbursement_by_key(key) == :ok

      t1_after = Transactions.get_transaction!(t1.id)
      t2_after = Transactions.get_transaction!(t2.id)

      assert t1_after.reimbursement_link_key == nil
      assert t1_after.reimbursement_status == "pending"
      assert t2_after.reimbursement_link_key == nil
      assert t2_after.reimbursement_status == nil
    end

    test "create_transaction/1 handles duplicate fingerprint" do
      account = AccountsFixtures.account_fixture()

      attrs = %{
        date: ~D[2026-02-23],
        description: "duplicate",
        amount: "100",
        account_id: account.id,
        fingerprint: "unique_fingerprint"
      }

      assert {:ok, _} = Transactions.create_transaction(attrs)
      assert {:ok, :duplicate} = Transactions.create_transaction(attrs)
    end
  end

  describe "bulk ignore patterns" do
    alias CashLens.Transactions.BulkIgnorePattern

    test "list_bulk_ignore_patterns/0 returns all patterns" do
      unique_pattern = "UNIQUE_#{System.unique_integer([:positive])}"
      pattern = insert_bulk_ignore_pattern(%{pattern: unique_pattern})
      assert Enum.any?(Transactions.list_bulk_ignore_patterns(), &(&1.id == pattern.id))
    end

    test "create_bulk_ignore_pattern/1 with valid data creates a pattern" do
      unique_pattern = "NEW_#{System.unique_integer([:positive])}"

      assert {:ok, %BulkIgnorePattern{} = pattern} =
               Transactions.create_bulk_ignore_pattern(%{pattern: unique_pattern})

      assert pattern.pattern == unique_pattern
    end
  end

  describe "crud operations" do
    test "create_transaction/1 with valid data" do
      account = AccountsFixtures.account_fixture()

      valid_attrs = %{
        date: ~D[2026-02-23],
        description: "some description",
        amount: "120.5",
        account_id: account.id
      }

      assert {:ok, %Transaction{} = transaction} = Transactions.create_transaction(valid_attrs)
      assert transaction.date == ~D[2026-02-23]
    end

    test "update_transaction/2" do
      transaction = transaction_fixture()

      assert {:ok, %Transaction{}} =
               Transactions.update_transaction(transaction, %{description: "new"})
    end

    test "delete_transaction/1" do
      transaction = transaction_fixture()
      assert {:ok, %Transaction{}} = Transactions.delete_transaction(transaction)
    end

    test "count_pending_transactions/0" do
      transaction_fixture(%{category_id: nil})
      assert Transactions.count_pending_transactions() >= 1
    end
  end
end
