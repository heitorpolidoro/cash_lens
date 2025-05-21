defmodule CashLens.TransactionsTest do
  use CashLens.DataCase

  alias CashLens.Transactions

  describe "categories" do
    alias CashLens.Transactions.Category

    import CashLens.TransactionsFixtures

    @invalid_attrs %{name: nil, type: nil}

    test "list_categories/0 returns all categories" do
      category = category_fixture()
      assert Transactions.list_categories() == [category]
    end

    test "get_category!/1 returns the category with given id" do
      category = category_fixture()
      assert Transactions.get_category!(category.id) == category
    end

    test "create_category/1 with valid data creates a category" do
      valid_attrs = %{name: "some category", type: "some type"}

      assert {:ok, %Category{} = category} = Transactions.create_category(valid_attrs)
      assert category.name == "some category"
      assert category.type == "some type"
    end

    test "create_category/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Transactions.create_category(@invalid_attrs)
    end

    test "update_category/2 with valid data updates the category" do
      category = category_fixture()
      update_attrs = %{name: "some updated category", type: "some updated type"}

      assert {:ok, %Category{} = category} = Transactions.update_category(category, update_attrs)
      assert category.name == "some updated category"
      assert category.type == "some updated type"
    end

    test "update_category/2 with invalid data returns error changeset" do
      category = category_fixture()
      assert {:error, %Ecto.Changeset{}} = Transactions.update_category(category, @invalid_attrs)
      assert category == Transactions.get_category!(category.id)
    end

    test "delete_category/1 deletes the category" do
      category = category_fixture()
      assert {:ok, %Category{}} = Transactions.delete_category(category)
      assert_raise Ecto.NoResultsError, fn -> Transactions.get_category!(category.id) end
    end

    test "change_category/1 returns a category changeset" do
      category = category_fixture()
      assert %Ecto.Changeset{} = Transactions.change_category(category)
    end
  end

  describe "transactions" do
    alias CashLens.Transactions.Transaction

    import CashLens.TransactionsFixtures

    @invalid_attrs %{date: nil, reason: nil, amount: nil, identifyer: nil}

    test "list_transactions/0 returns all transactions" do
      transaction = transaction_fixture()
      assert Transactions.list_transactions() == [transaction]
    end

    test "get_transaction!/1 returns the transaction with given id" do
      transaction = transaction_fixture()
      assert Transactions.get_transaction!(transaction.id) == transaction
    end

    test "create_transaction/1 with valid data creates a transaction" do
      category = category_fixture()
      valid_attrs = %{
        date: ~D[2024-06-01],
        time: ~T[12:00:00],
        reason: "some reason",
        category_id: category.id,
        amount: "120.5"
      }

      assert {:ok, %Transaction{} = transaction} = Transactions.create_transaction(valid_attrs)
      assert transaction.date == ~D[2024-06-01]
      assert transaction.time == ~T[12:00:00]
      assert transaction.reason == "some reason"
      assert transaction.category_id == category.id
      assert Decimal.equal?(transaction.amount, Decimal.new("120.5"))
    end

    test "create_transaction/1 with nullable fields creates a transaction" do
      valid_attrs = %{
        date: ~D[2024-06-01],
        reason: "some reason",
        amount: "120.5"
      }

      assert {:ok, %Transaction{} = transaction} = Transactions.create_transaction(valid_attrs)
      assert transaction.date == ~D[2024-06-01]
      assert transaction.time == nil
      assert transaction.reason == "some reason"
      assert transaction.category == nil
      assert Decimal.equal?(transaction.amount, Decimal.new("120.5"))
    end

    test "create_transaction/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Transactions.create_transaction(@invalid_attrs)
    end

    test "update_transaction/2 with valid data updates the transaction" do
      transaction = transaction_fixture()
      category = category_fixture(%{name: "some updated category", type: "some updated type"})
      update_attrs = %{
        date: ~D[2024-06-02],
        time: ~T[14:30:00],
        reason: "some updated reason",
        category_id: category.id,
        amount: "456.7"
      }

      assert {:ok, %Transaction{} = transaction} = Transactions.update_transaction(transaction, update_attrs)
      assert transaction.date == ~D[2024-06-02]
      assert transaction.time == ~T[14:30:00]
      assert transaction.reason == "some updated reason"
      assert transaction.category_id == category.id
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
