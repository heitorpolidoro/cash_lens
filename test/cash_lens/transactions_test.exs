defmodule CashLens.TransactionsTest do
  use CashLens.DataCase

  alias CashLens.Transactions

  describe "transactions" do
    alias CashLens.Transactions.Transaction

    import CashLens.TransactionsFixtures

    @invalid_attrs %{date: nil, description: nil, category: nil, amount: nil}

    test "list_transactions/0 returns all transactions" do
      transaction = transaction_fixture()
      [fetched] = Transactions.list_transactions()
      assert fetched.id == transaction.id
    end

    test "get_transaction!/1 returns the transaction with given id" do
      transaction = transaction_fixture()
      fetched = Transactions.get_transaction!(transaction.id)
      assert fetched.id == transaction.id
      assert fetched.account_id == transaction.account_id
    end

    test "create_transaction/1 with valid data creates a transaction" do
      account = CashLens.AccountsFixtures.account_fixture()
      valid_attrs = %{date: ~D[2026-02-23], description: "some description", amount: "120.5", account_id: account.id}

      assert {:ok, %Transaction{} = transaction} = Transactions.create_transaction(valid_attrs)
      assert transaction.date == ~D[2026-02-23]
      assert transaction.description == "some description"
      assert transaction.account_id == account.id
      assert transaction.amount == Decimal.new("120.5")
    end

    test "create_transaction/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Transactions.create_transaction(@invalid_attrs)
    end

    test "update_transaction/2 with valid data updates the transaction" do
      transaction = transaction_fixture()
      update_attrs = %{date: ~D[2026-02-24], description: "some updated description", amount: "456.7"}

      assert {:ok, %Transaction{} = transaction} = Transactions.update_transaction(transaction, update_attrs)
      assert transaction.date == ~D[2026-02-24]
      assert transaction.description == "some updated description"
      assert transaction.amount == Decimal.new("456.7")
    end

    test "update_transaction/2 with invalid data returns error changeset" do
      transaction = transaction_fixture()
      assert {:error, %Ecto.Changeset{}} = Transactions.update_transaction(transaction, @invalid_attrs)
      assert Transactions.get_transaction!(transaction.id).id == transaction.id
    end

    test "delete_transaction/1 deletes the transaction" do
      transaction = transaction_fixture()
      assert {:ok, %Transaction{}} = Transactions.delete_transaction(transaction)
      assert_raise Ecto.NoResultsError, fn -> Transactions.get_transaction!(transaction.id) end
    end

    test "change_transaction/1 returns a transaction changeset" do
      transaction = transaction_fixture()
      assert %Ecto.Changeset{} = Transactions.change_transaction(transaction)
    end
  end
end
