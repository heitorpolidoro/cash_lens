defmodule CashLens.TransactionsTest do
  use CashLens.DataCase

  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction
  alias CashLens.AccountsFixtures
  alias CashLens.CategoriesFixtures

  import CashLens.TransactionsFixtures

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

    test "filters by amount range" do
      _t1 = transaction_fixture(%{amount: "50.00"})
      t2 = transaction_fixture(%{amount: "150.00"})
      _t3 = transaction_fixture(%{amount: "250.00"})

      results =
        Transactions.list_transactions(%{"amount_min" => "100.00", "amount_max" => "200.00"})

      assert length(results) == 1
      assert Enum.at(results, 0).id == t2.id
    end

    test "filters by exact date" do
      t1 = transaction_fixture(%{date: ~D[2026-01-01]})
      _t2 = transaction_fixture(%{date: ~D[2026-01-02]})

      results = Transactions.list_transactions(%{"date" => "2026-01-01"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t1.id
    end

    test "filters by month and year" do
      t1 = transaction_fixture(%{date: ~D[2026-01-15]})
      _t2 = transaction_fixture(%{date: ~D[2026-02-15]})
      _t3 = transaction_fixture(%{date: ~D[2025-01-15]})

      results = Transactions.list_transactions(%{"month" => "1", "year" => "2026"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t1.id
    end

    test "filters by category including hierarchy" do
      parent = CategoriesFixtures.category_fixture(%{name: "Food", slug: "food"})

      child =
        CategoriesFixtures.category_fixture(%{
          name: "Dining Out",
          slug: "dining",
          parent_id: parent.id
        })

      t1 = transaction_fixture(%{category_id: parent.id})
      t2 = transaction_fixture(%{category_id: child.id})
      _t3 = transaction_fixture(%{category_id: nil})

      results = Transactions.list_transactions(%{"category_id" => parent.id})
      assert length(results) == 2
      assert Enum.any?(results, fn r -> r.id == t1.id end)
      assert Enum.any?(results, fn r -> r.id == t2.id end)

      results_child = Transactions.list_transactions(%{"category_id" => child.id})
      assert length(results_child) == 1
      assert Enum.at(results_child, 0).id == t2.id
    end

    test "filters by 'nil' category (pending transactions)" do
      _t1 = transaction_fixture(%{category_id: CategoriesFixtures.category_fixture().id})
      t2 = transaction_fixture(%{category_id: nil})

      results = Transactions.list_transactions(%{"category_id" => "nil"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t2.id
    end

    test "filters by unmatched transfers" do
      transfer_cat = CategoriesFixtures.category_fixture(%{name: "Transfer", slug: "transfer"})
      t1 = transaction_fixture(%{category_id: transfer_cat.id, transfer_key: nil})

      _t2 =
        transaction_fixture(%{category_id: transfer_cat.id, transfer_key: Ecto.UUID.generate()})

      _t3 = transaction_fixture(%{category_id: nil})

      results = Transactions.list_transactions(%{"unmatched_transfers" => "true"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t1.id
    end

    test "filters by type (debit/credit)" do
      t1 = transaction_fixture(%{amount: "-10.00"})
      t2 = transaction_fixture(%{amount: "10.00"})

      debits = Transactions.list_transactions(%{"type" => "debit"})
      assert length(debits) == 1
      assert Enum.at(debits, 0).id == t1.id

      credits = Transactions.list_transactions(%{"type" => "credit"})
      assert length(credits) == 1
      assert Enum.at(credits, 0).id == t2.id
    end

    test "filters by reimbursement status" do
      t1 = transaction_fixture(%{reimbursement_status: "pending"})
      _t2 = transaction_fixture(%{reimbursement_status: nil})

      results = Transactions.list_transactions(%{"reimbursement_status" => "pending"})
      assert length(results) == 1
      assert Enum.at(results, 0).id == t1.id
    end
  end

  describe "summaries" do
    test "get_monthly_summary/2 calculates income and expenses correctly" do
      acc = AccountsFixtures.account_fixture()

      # We need specific slugs for some categories to test exclusions
      cat_transfer =
        Repo.insert!(%CashLens.Categories.Category{name: "Transfer", slug: "transfer"})

      cat_initial =
        Repo.insert!(%CashLens.Categories.Category{name: "Initial", slug: "initial_value"})

      cat_expense = CategoriesFixtures.category_fixture(%{name: "Expense"})

      # Valid income
      transaction_fixture(%{amount: "1000.00", date: ~D[2026-03-01], account_id: acc.id})
      # Valid expense
      transaction_fixture(%{
        amount: "-200.00",
        date: ~D[2026-03-05],
        account_id: acc.id,
        category_id: cat_expense.id
      })

      # Ignored: Transfer
      transaction_fixture(%{
        amount: "-500.00",
        date: ~D[2026-03-10],
        account_id: acc.id,
        category_id: cat_transfer.id
      })

      # Ignored: Initial value
      transaction_fixture(%{
        amount: "10000.00",
        date: ~D[2026-03-12],
        account_id: acc.id,
        category_id: cat_initial.id
      })

      # Ignored: Linked reimbursement
      transaction_fixture(%{
        amount: "200.00",
        date: ~D[2026-03-15],
        account_id: acc.id,
        reimbursement_link_key: Ecto.UUID.generate()
      })

      summary = Transactions.get_monthly_summary(~D[2026-03-01])

      assert summary.income == Decimal.new("1000.00")
      assert summary.expenses == Decimal.new("200.00")
      assert summary.month == ~D[2026-03-01]
    end

    test "get_monthly_summary/2 with explicit filters" do
      acc = AccountsFixtures.account_fixture()
      transaction_fixture(%{amount: "100.00", date: ~D[2025-01-15], account_id: acc.id})

      summary = Transactions.get_monthly_summary(nil, %{"month" => "1", "year" => "2025"})
      assert summary.income == Decimal.new("100.00")
      assert summary.month == ~D[2025-01-01]
    end

    test "get_historical_summary/0 returns correct data grouped by month" do
      acc = AccountsFixtures.account_fixture()

      # February
      transaction_fixture(%{amount: "1000.00", date: ~D[2026-02-01], account_id: acc.id})
      transaction_fixture(%{amount: "-100.00", date: ~D[2026-02-10], account_id: acc.id})

      # March
      transaction_fixture(%{amount: "1500.00", date: ~D[2026-03-01], account_id: acc.id})
      transaction_fixture(%{amount: "-500.00", date: ~D[2026-03-05], account_id: acc.id})

      history = Transactions.get_historical_summary()

      assert length(history) >= 2

      feb = Enum.find(history, &(&1.month == 2 and &1.year == 2026))
      assert feb.income == Decimal.new("1000.00")
      assert feb.expenses == Decimal.new("100.00")
      assert feb.balance == Decimal.new("900.00")

      mar = Enum.find(history, &(&1.month == 3 and &1.year == 2026))
      assert mar.income == Decimal.new("1500.00")
      assert mar.expenses == Decimal.new("500.00")
      assert mar.balance == Decimal.new("1000.00")
    end

    test "get_historical_category_summary/0" do
      cat = CategoriesFixtures.category_fixture(%{name: "Food", type: "fixed"})
      transaction_fixture(%{amount: "-50.00", date: ~D[2026-04-01], category_id: cat.id})

      results = Transactions.get_historical_category_summary()
      assert length(results) > 0
      month_data = Enum.find(results, &(&1.month == 4 and &1.year == 2026))
      assert month_data
      cat_data = Enum.find(month_data.categories, &(&1.name == "Food"))
      assert cat_data.total == Decimal.new("50.00")
      assert cat_data.type == "fixed"
    end
  end

  describe "reapply_auto_categorization/0" do
    test "assigns categories based on keyword rules" do
      cat =
        CategoriesFixtures.category_fixture(%{
          name: "Streaming",
          slug: "streaming",
          keywords: "NETFLIX, SPOTIFY"
        })

      t1 = transaction_fixture(%{description: "NETFLIX COM", category_id: nil})
      t2 = transaction_fixture(%{description: "SPOTIFY SA", category_id: nil})
      t3 = transaction_fixture(%{description: "Other stuff", category_id: nil})

      assert :ok = Transactions.reapply_auto_categorization()

      assert Transactions.get_transaction!(t1.id).category_id == cat.id
      assert Transactions.get_transaction!(t2.id).category_id == cat.id
      assert Transactions.get_transaction!(t3.id).category_id == nil
    end

    test "assigns categories based on special hardcoded rules" do
      # BB MM OURO is a transfer according to AutoCategorizer
      transfer_cat = CategoriesFixtures.category_fixture(%{name: "Transfer", slug: "transfer"})

      t = transaction_fixture(%{description: "BB MM OURO", category_id: nil})

      assert :ok = Transactions.reapply_auto_categorization()

      assert Transactions.get_transaction!(t.id).category_id == transfer_cat.id
    end
  end

  describe "crud operations" do
    test "get_transaction!/1 returns the transaction with given id" do
      transaction = transaction_fixture()
      fetched = Transactions.get_transaction!(transaction.id)
      assert fetched.id == transaction.id
    end

    test "create_transaction/1 with valid data creates a transaction" do
      account = AccountsFixtures.account_fixture()

      valid_attrs = %{
        date: ~D[2026-02-23],
        description: "some description",
        amount: "120.5",
        account_id: account.id
      }

      assert {:ok, %Transaction{} = transaction} = Transactions.create_transaction(valid_attrs)
      assert transaction.date == ~D[2026-02-23]
      assert transaction.amount == Decimal.new("120.5")
    end

    test "create_transaction/1 with duplicate fingerprint returns :duplicate" do
      account = AccountsFixtures.account_fixture()

      attrs = %{
        date: ~D[2026-02-23],
        description: "unique",
        amount: "120.5",
        account_id: account.id
      }

      _t1 = transaction_fixture(attrs)

      # Let's verify both fingerprints
      assert {:ok, :duplicate} = Transactions.create_transaction(attrs)
    end

    test "update_transaction/2 with valid data updates the transaction" do
      transaction = transaction_fixture()
      update_attrs = %{description: "updated description"}

      assert {:ok, %Transaction{} = transaction} =
               Transactions.update_transaction(transaction, update_attrs)

      assert transaction.description == "updated description"
    end

    test "update_transaction_category/2" do
      transaction = transaction_fixture(%{category_id: nil})
      cat = CategoriesFixtures.category_fixture()
      assert {:ok, updated} = Transactions.update_transaction_category(transaction.id, cat.id)
      assert updated.category_id == cat.id
    end

    test "delete_transaction/1 deletes the transaction" do
      transaction = transaction_fixture()
      assert {:ok, %Transaction{}} = Transactions.delete_transaction(transaction)
      assert_raise Ecto.NoResultsError, fn -> Transactions.get_transaction!(transaction.id) end
    end

    test "unlink_reimbursement_by_key/1" do
      key = Ecto.UUID.generate()

      t1 =
        transaction_fixture(%{
          amount: "-100.00",
          reimbursement_link_key: key,
          reimbursement_status: "paid"
        })

      t2 =
        transaction_fixture(%{
          amount: "100.00",
          reimbursement_link_key: key,
          reimbursement_status: "paid"
        })

      assert :ok = Transactions.unlink_reimbursement_by_key(key)

      updated_t1 = Transactions.get_transaction!(t1.id)
      assert updated_t1.reimbursement_link_key == nil
      assert updated_t1.reimbursement_status == "pending"

      updated_t2 = Transactions.get_transaction!(t2.id)
      assert updated_t2.reimbursement_link_key == nil
      assert updated_t2.reimbursement_status == nil
    end

    test "count_pending_transactions/0" do
      transaction_fixture(%{category_id: nil})
      cat = CategoriesFixtures.category_fixture()
      transaction_fixture(%{category_id: cat.id})

      assert Transactions.count_pending_transactions() >= 1
    end

    test "list_recent_transactions/1" do
      transaction_fixture()
      assert length(Transactions.list_recent_transactions(1)) == 1
    end

    test "delete_all_transactions/0" do
      transaction_fixture()
      assert {_, nil} = Transactions.delete_all_transactions()
      assert length(Transactions.list_transactions()) == 0
    end
  end
end
