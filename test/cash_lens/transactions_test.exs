defmodule CashLens.TransactionsTest do
  use ExUnit.Case, async: true

  alias CashLens.Transactions
  alias CashLens.Transaction
  alias CashLens.Account
  alias CashLens.Repo
  alias MongoDB.BSON.ObjectId

  setup do
    # Ensure the test database is clean before each test
    :ok = Repo.delete_all(Transaction)
    :ok = Repo.delete_all(Account) # Need an account for transactions

    user_id = ObjectId.generate()
    {:ok, account} = CashLens.Accounts.create_account(%{name: "Test Account", user_id: user_id})

    %{account: account, user_id: user_id}
  end

  test "create_transaction/1 with valid attributes", %{account: account} do
    attrs = %{
      date: ~D[2025-01-01],
      description: "Groceries",
      amount: Decimal.new("-50.00"),
      type: "expense",
      account_id: account.id
    }
    {:ok, transaction} = Transactions.create_transaction(attrs)
    assert transaction.date == ~D[2025-01-01]
    assert transaction.description == "Groceries"
    assert transaction.amount == Decimal.new("-50.00")
    assert transaction.type == "expense"
    assert transaction.account_id == account.id
    assert transaction.id != nil
    assert transaction.inserted_at != nil
  end

  test "create_transaction/1 with invalid attributes (missing amount)" do
    attrs = %{
      date: ~D[2025-01-01],
      description: "Groceries",
      type: "expense",
      account_id: ObjectId.generate()
    }
    {:error, changeset} = Transactions.create_transaction(attrs)
    assert changeset.errors[:amount] == {"can't be blank", [validation: :required]}
  end

  test "create_transaction/1 with invalid type" do
    attrs = %{
      date: ~D[2025-01-01],
      description: "Groceries",
      amount: Decimal.new("-50.00"),
      type: "invalid_type",
      account_id: ObjectId.generate()
    }
    {:error, changeset} = Transactions.create_transaction(attrs)
    assert changeset.errors[:type] == {"is invalid", [validation: :inclusion, enum: ["income", "expense"]]}
  end

  test "bulk_insert_transactions/1 with valid transactions", %{account: account} do
    transactions_attrs = [
      %{date: ~D[2025-01-01], description: "Groceries", amount: Decimal.new("-50.00"), type: "expense", account_id: account.id},
      %{date: ~D[2025-01-02], description: "Salary", amount: Decimal.new("2000.00"), type: "income", account_id: account.id}
    ]

    {:ok, %{inserted_count: count}} = Transactions.bulk_insert_transactions(transactions_attrs)
    assert count == 2

    # Verify transactions were inserted
    inserted_transactions = Repo.all(Transaction)
    assert length(inserted_transactions) == 2
    assert Enum.any?(inserted_transactions, &(&1.description == "Groceries"))
    assert Enum.any?(inserted_transactions, &(&1.description == "Salary"))
  end

  test "bulk_insert_transactions/1 with some invalid transactions (validation fails for invalid ones)", %{account: account} do
    transactions_attrs = [
      %{date: ~D[2025-01-01], description: "Valid", amount: Decimal.new("-10.00"), type: "expense", account_id: account.id},
      %{description: "Invalid (missing amount)", type: "expense", account_id: account.id} # Invalid
    ]

    {:ok, %{inserted_count: count}} = Transactions.bulk_insert_transactions(transactions_attrs)
    assert count == 1 # Only the valid one should be inserted

    inserted_transactions = Repo.all(Transaction)
    assert length(inserted_transactions) == 1
    assert Enum.any?(inserted_transactions, &(&1.description == "Valid"))
    assert Enum.all?(inserted_transactions, &(&1.account_id == account.id))
  end

  test "get_monthly_summary_for_user/1 calculates correct monthly summaries", %{account: account, user_id: user_id} do
    # Insert some transactions for different months and types
    Transactions.bulk_insert_transactions([
      # January
      %{date: ~D[2025-01-05], description: "Salary", amount: Decimal.new("3000.00"), type: "income", account_id: account.id},
      %{date: ~D[2025-01-10], description: "Rent", amount: Decimal.new("-1000.00"), type: "expense", account_id: account.id},
      %{date: ~D[2025-01-15], description: "Groceries", amount: Decimal.new("-200.00"), type: "expense", account_id: account.id},
      # February
      %{date: ~D[2025-02-01], description: "Freelance", amount: Decimal.new("500.00"), type: "income", account_id: account.id},
      %{date: ~D[2025-02-10], description: "Utilities", amount: Decimal.new("-150.00"), type: "expense", account_id: account.id}
    ])

    {:ok, summary} = Transactions.get_monthly_summary_for_user(user_id)
    assert length(summary) == 2

    # Verify January summary
    january_summary = Enum.find(summary, &(&1["year"] == 2025 && &1["month"] == 1))
    assert january_summary["income"] == Decimal.new("3000.00")
    assert january_summary["expense"] == Decimal.new("1200.00") # Absolute value
    assert january_summary["monthly_balance"] == Decimal.new("1800.00") # 3000 - 1000 - 200
    assert january_summary["final_balance"] == Decimal.new("1800.00")

    # Verify February summary
    february_summary = Enum.find(summary, &(&1["year"] == 2025 && &1["month"] == 2))
    assert february_summary["income"] == Decimal.new("500.00")
    assert february_summary["expense"] == Decimal.new("150.00")
    assert february_summary["monthly_balance"] == Decimal.new("350.00") # 500 - 150
    assert february_summary["final_balance"] == Decimal.new("2150.00") # 1800 + 350

    # Test with no data
    :ok = Repo.delete_all(Transaction)
    {:ok, empty_summary} = Transactions.get_monthly_summary_for_user(user_id)
    assert empty_summary == []
  end

  test "get_monthly_summary_for_user/1 handles multiple accounts correctly", %{user_id: user_id} do
    {:ok, account_b} = CashLens.Accounts.create_account(%{name: "Account B", user_id: user_id})

    # Transactions for original account
    Transactions.bulk_insert_transactions([
      %{date: ~D[2025-01-05], description: "Salary A", amount: Decimal.new("1000.00"), type: "income", account_id: account.id}
    ])

    # Transactions for account B
    Transactions.bulk_insert_transactions([
      %{date: ~D[2025-01-05], description: "Salary B", amount: Decimal.new("2000.00"), type: "income", account_id: account_b.id}
    ])

    {:ok, summary} = Transactions.get_monthly_summary_for_user(user_id)
    assert length(summary) == 1
    assert Enum.find(summary, &(&1["year"] == 2025 && &1["month"] == 1))["income"] == Decimal.new("3000.00") # Total across all accounts for user
  end
end
