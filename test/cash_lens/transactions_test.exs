defmodule CashLens.TransactionsTest do
  use CashLens.DataCase

  alias CashLens.Transactions

  describe "transactions" do
    alias CashLens.Transactions.Transaction

    import CashLens.TransactionsFixtures

    @invalid_attrs %{date: nil, time: nil, reason: nil, category: nil, amount: nil}

    test "list_transactions/0 returns all transactions" do
      transaction = transaction_fixture()
      assert Transactions.list_transactions() == [transaction]
    end

    test "get_transaction!/1 returns the transaction with given id" do
      transaction = transaction_fixture()
      assert Transactions.get_transaction!(transaction.id) == transaction
    end

    test "create_transaction/1 with valid data creates a transaction" do
      valid_attrs = %{
        date: ~D[2024-06-01],
        time: ~T[12:00:00],
        reason: "some reason",
        category: "some category",
        amount: "120.5"
      }

      assert {:ok, %Transaction{} = transaction} = Transactions.create_transaction(valid_attrs)
      assert transaction.date == ~D[2024-06-01]
      assert transaction.time == ~T[12:00:00]
      assert transaction.reason == "some reason"
      assert transaction.category == "some category"
      assert Decimal.equal?(transaction.amount, Decimal.new("120.5"))
    end

    test "create_transaction/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Transactions.create_transaction(@invalid_attrs)
    end

    test "update_transaction/2 with valid data updates the transaction" do
      transaction = transaction_fixture()
      update_attrs = %{
        date: ~D[2024-06-02],
        time: ~T[14:30:00],
        reason: "some updated reason",
        category: "some updated category",
        amount: "456.7"
      }

      assert {:ok, %Transaction{} = transaction} = Transactions.update_transaction(transaction, update_attrs)
      assert transaction.date == ~D[2024-06-02]
      assert transaction.time == ~T[14:30:00]
      assert transaction.reason == "some updated reason"
      assert transaction.category == "some updated category"
      assert Decimal.equal?(transaction.amount, Decimal.new("456.7"))
    end

    test "update_transaction/2 with invalid data returns error changeset" do
      transaction = transaction_fixture()
      assert {:error, %Ecto.Changeset{}} = Transactions.update_transaction(transaction, @invalid_attrs)
      assert transaction == Transactions.get_transaction!(transaction.id)
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
