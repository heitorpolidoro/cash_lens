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
  @doc """
  Returns the list of transactions based on filters and pagination.
  """
  def list_transactions(filters \\ %{}, page \\ 1, page_size \\ 50) do
    IO.inspect(filters, label: "Executing list_transactions with filters")
    offset = (page - 1) * page_size

    Transaction
    |> join_associations()
    |> filter_by_account(filters["account_id"])
    |> filter_by_category(filters["category_id"])
    |> filter_by_description(filters["search"])
    |> filter_by_date(filters["date"])
    |> filter_by_amount(filters["amount"])
    |> order_by([t], desc: t.date, desc: t.inserted_at)
    |> limit(^page_size)
    |> offset(^offset)
    |> Repo.all()
  end

  defp join_associations(query) do
    query
    |> preload([:category, :account])
  end

  defp filter_by_date(query, nil), do: query
  defp filter_by_date(query, ""), do: query
  defp filter_by_date(query, date), do: where(query, date: ^date)

  defp filter_by_amount(query, nil), do: query
  defp filter_by_amount(query, ""), do: query
  defp filter_by_amount(query, amount) do
    where(query, amount: ^amount)
  end

  defp filter_by_account(query, nil), do: query
  defp filter_by_account(query, ""), do: query
  defp filter_by_account(query, account_id), do: where(query, account_id: ^account_id)

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, ""), do: query
  defp filter_by_category(query, "nil"), do: where(query, [t], is_nil(t.category_id))
  defp filter_by_category(query, category_id), do: where(query, category_id: ^category_id)

  defp filter_by_description(query, nil), do: query
  defp filter_by_description(query, ""), do: query
  defp filter_by_description(query, search) do
    where(query, [t], ilike(t.description, ^"%#{search}%"))
  end

  @doc """
  Lists the most recent transactions with a limit.
  """
  def list_recent_transactions(limit \\ 5) do
    Repo.all(from t in Transaction, order_by: [desc: t.date, desc: t.inserted_at], limit: ^limit, preload: [:category])
  end

  @doc """
  Calculates monthly totals for income (positive) and expenses (negative), ignoring transfers.
  Defaults to the current month, or the month of the last transaction if none in current.
  """
  def get_monthly_summary(date \\ nil) do
    target_date = date || get_latest_transaction_date() || Date.utc_today()
    first_of_month = Date.beginning_of_month(target_date)
    last_of_month = Date.end_of_month(target_date)

    query = from t in Transaction,
      left_join: c in assoc(t, :category),
      where: t.date >= ^first_of_month and t.date <= ^last_of_month,
      where: is_nil(c.slug) or c.slug not in ["initial_value", "transfer"],
      select: t

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

  @doc """
  Returns pure income and expenses history grouped by month, excluding transfers.
  """
  def get_historical_summary do
    query = from t in Transaction,
      left_join: c in assoc(t, :category),
      where: is_nil(c.slug) or c.slug not in ["initial_value", "transfer"],
      select: t

    Repo.all(query)
    |> Enum.group_by(fn t -> {t.date.year, t.date.month} end)
    |> Enum.map(fn {{year, month}, txs} ->
      income = 
        txs 
        |> Enum.filter(&Decimal.gt?(&1.amount, 0)) 
        |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))
      
      expenses = 
        txs 
        |> Enum.filter(&Decimal.lt?(&1.amount, 0)) 
        |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount)) 
        |> Decimal.abs()

      %{
        year: year,
        month: month,
        income: income,
        expenses: expenses,
        balance: Decimal.sub(income, expenses)
      }
    end)
    |> Enum.sort_by(fn %{year: y, month: m} -> {y, m} end)
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
  def get_transaction!(id), do: Repo.get!(Transaction, id) |> Repo.preload(:category)

  @doc """
  Creates a transaction.

  ## Examples

      iex> create_transaction(%{field: value})
      {:ok, %Transaction{}}

      iex> create_transaction(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_transaction(attrs) do
    # Generate changeset to get the fingerprint
    changeset = Transaction.changeset(%Transaction{}, attrs)

    # Insert with conflict handling
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :fingerprint) do
      {:ok, %Transaction{id: nil}} -> 
        # This happens when on_conflict: :nothing triggers
        {:ok, :duplicate}
      
      {:ok, transaction} -> 
        CashLens.Transactions.TransferMatcher.match_transfer(transaction)
        {:ok, transaction}
      
      {:error, changeset} -> 
        {:error, changeset}
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
  end

  @doc """
  Quickly updates the category of a transaction by ID.
  """
  def update_transaction_category(id, category_id) do
    transaction = get_transaction!(id)
    
    transaction
    |> Ecto.Changeset.change(category_id: category_id)
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
  Deletes all transactions from the database.
  """
  def delete_all_transactions do
    Repo.delete_all(Transaction)
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
