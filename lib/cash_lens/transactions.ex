defmodule CashLens.Transactions do
  @moduledoc """
  The Transactions context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Transactions.Transaction

  @doc """
  Returns the list of transactions.

  ## Examples

      iex> list_transactions()
      [%Transaction{}, ...]

  """
  def list_transactions do
    Repo.all(from t in Transaction, order_by: [desc: t.date, desc: t.inserted_at])
  end

  @doc """
  Lists the most recent transactions with a limit.
  """
  def list_recent_transactions(limit \\ 5) do
    Repo.all(from t in Transaction, order_by: [desc: t.date, desc: t.inserted_at], limit: ^limit)
  end

  @doc """
  Calculates monthly totals for income (positive) and expenses (negative).
  Defaults to the current month, or the month of the last transaction if none in current.
  """
  def get_monthly_summary(date \\ nil) do
    target_date = date || get_latest_transaction_date() || Date.utc_today()
    first_of_month = Date.beginning_of_month(target_date)
    last_of_month = Date.end_of_month(target_date)

    query = from t in Transaction,
      where: t.date >= ^first_of_month and t.date <= ^last_of_month

    transactions = Repo.all(query)

    income = 
      transactions 
      |> Enum.filter(fn t -> Decimal.gt?(t.amount, 0) end)
      |> Enum.reduce(Decimal.new("0"), fn t, acc -> Decimal.add(acc, t.amount) end)

    expenses = 
      transactions 
      |> Enum.filter(fn t -> Decimal.lt?(t.amount, 0) end)
      |> Enum.reduce(Decimal.new("0"), fn t, acc -> Decimal.add(acc, t.amount) end)

    %{income: income, expenses: Decimal.abs(expenses), month: target_date}
  end

  defp get_latest_transaction_date do
    Repo.one(from t in Transaction, select: max(t.date))
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
  def get_transaction!(id), do: Repo.get!(Transaction, id)

  @doc """
  Creates a transaction.

  ## Examples

      iex> create_transaction(%{field: value})
      {:ok, %Transaction{}}

      iex> create_transaction(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_transaction(attrs) do
    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
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
end
