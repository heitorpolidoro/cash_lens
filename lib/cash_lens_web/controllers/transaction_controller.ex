defmodule CashLensWeb.TransactionController do
  use CashLensWeb, :controller

  alias CashLens.Transactions
  alias CashLens.Transactions.Transaction

  def index(conn, _params) do
    transactions = Transactions.list_transactions()
    render(conn, :index, transactions: transactions)
  end

  def new(conn, _params) do
    changeset = Transactions.change_transaction(%Transaction{datetime: DateTime.utc_now()})
    accounts = Transactions.list_accounts_for_select()
    categories = Transactions.list_categories_for_select()
    render(conn, :new, changeset: changeset, accounts: accounts, categories: categories)
  end

  def create(conn, %{"transaction" => transaction_params}) do
    case Transactions.create_transaction(transaction_params) do
      {:ok, _transaction} ->
        conn
        |> put_flash(:info, "Transaction created successfully.")
        |> redirect(to: ~p"/transactions")

      {:error, %Ecto.Changeset{} = changeset} ->
        accounts = Transactions.list_accounts_for_select()
        categories = Transactions.list_categories_for_select()
        render(conn, :new, changeset: changeset, accounts: accounts, categories: categories)
    end
  end

  def show(conn, %{"id" => id}) do
    transaction = Transactions.get_transaction!(id)
    render(conn, :show, transaction: transaction)
  end

  def edit(conn, %{"id" => id}) do
    transaction = Transactions.get_transaction!(id)
    changeset = Transactions.change_transaction(transaction)
    accounts = Transactions.list_accounts_for_select()
    categories = Transactions.list_categories_for_select()
    render(conn, :edit, transaction: transaction, changeset: changeset, accounts: accounts, categories: categories)
  end

  def update(conn, %{"id" => id, "transaction" => transaction_params}) do
    transaction = Transactions.get_transaction!(id)

    case Transactions.update_transaction(transaction, transaction_params) do
      {:ok, _transaction} ->
        conn
        |> put_flash(:info, "Transaction updated successfully.")
        |> redirect(to: ~p"/transactions")

      {:error, %Ecto.Changeset{} = changeset} ->
        accounts = Transactions.list_accounts_for_select()
        categories = Transactions.list_categories_for_select()
        render(conn, :edit, transaction: transaction, changeset: changeset, accounts: accounts, categories: categories)
    end
  end

  def delete(conn, %{"id" => id}) do
    transaction = Transactions.get_transaction!(id)
    {:ok, _transaction} = Transactions.delete_transaction(transaction)

    conn
    |> put_flash(:info, "Transaction deleted successfully.")
    |> redirect(to: ~p"/transactions")
  end
end
