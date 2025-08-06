defmodule CashLens.Transactions do
  @moduledoc """
  The Transactions context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Transactions.Transaction
  alias CashLens.Accounts.Account
  alias CashLens.Categories.Category

  @doc """
  Returns the list of transactions.

  ## Examples

      iex> list_transactions()
      [%Transaction{}, ...]

  """
  def list_transactions do
    Transaction
    |> Repo.all()
    |> Repo.preload([:account, :category])
  end

  @doc """
  Gets a single transaction.

  Raises `Ecto.NoResultsError` if the Transaction does not exist.

  ## Examples

      iex> get_transaction!(123)
      %Transaction{}

      iex> get_transaction!(456)
      ** (Ecto.NoResultsError)

  """
  def get_transaction!(id) do
    Transaction
    |> Repo.get!(id)
    |> Repo.preload([:account, :category])
  end

  @doc """
  Creates a transaction.

  ## Examples

      iex> create_transaction(%{field: value})
      {:ok, %Transaction{}}

      iex> create_transaction(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_transaction(attrs \\ %{}) do
    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, transaction} -> {:ok, Repo.preload(transaction, [:account, :category])}
      error -> error
    end
  end

  @doc """
  Updates a transaction.

  ## Examples

      iex> update_transaction(transaction, %{field: new_value})
      {:ok, %Transaction{}}

      iex> update_transaction(transaction, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_transaction(%Transaction{} = transaction, attrs) do
    transaction
    |> Transaction.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, transaction} -> {:ok, Repo.preload(transaction, [:account, :category])}
      error -> error
    end
  end

  @doc """
  Deletes a transaction.

  ## Examples

      iex> delete_transaction(transaction)
      {:ok, %Transaction{}}

      iex> delete_transaction(transaction)
      {:error, %Ecto.Changeset{}}

  """
  def delete_transaction(%Transaction{} = transaction) do
    Repo.delete(transaction)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking transaction changes.

  ## Examples

      iex> change_transaction(transaction)
      %Ecto.Changeset{data: %Transaction{}}

  """
  def change_transaction(%Transaction{} = transaction, attrs \\ %{}) do
    Transaction.changeset(transaction, attrs)
  end

  @doc """
  Returns a list of accounts for select options.
  """
  def list_accounts_for_select do
    Repo.all(from a in Account, select: {a.name, a.id}, order_by: a.name)
  end

  @doc """
  Returns a list of categories for select options.
  """
  def list_categories_for_select do
    Repo.all(from c in Category, select: {c.name, c.id}, order_by: c.name)
  end
end
