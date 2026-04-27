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
