defmodule CashLens.Transactions do
  @moduledoc """
  The Transactions context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Transactions.Transaction

  @doc """
  Returns the list of transactions based on filters and pagination.
  """
  def list_transactions(filters \\ %{}, page \\ 1, page_size \\ 50) do
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
    Repo.all(from t in Transaction, order_by: [desc: t.date, desc: t.inserted_at], limit: ^limit, preload: [:category, :account])
  end

  @doc """
  Calculates monthly totals for income (positive) and expenses (negative), ignoring transfers.
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

  @doc """
  Returns expense totals grouped by month and category, excluding transfers.
  """
  def get_historical_category_summary do
    query = from t in Transaction,
      join: c in assoc(t, :category),
      left_join: p in assoc(c, :parent),
      where: t.amount < 0,
      where: c.slug not in ["initial_value", "transfer"],
      select: %{
        year: fragment("EXTRACT(YEAR FROM ?)", t.date), 
        month: fragment("EXTRACT(MONTH FROM ?)", t.date), 
        category_name: c.name,
        parent_name: p.name,
        total: t.amount
      }

    Repo.all(query)
    |> Enum.group_by(fn item -> 
      year = if is_struct(item.year, Decimal), do: Decimal.to_integer(item.year), else: item.year
      month = if is_struct(item.month, Decimal), do: Decimal.to_integer(item.month), else: item.month
      {year, month} 
    end)
    |> Enum.map(fn {{year, month}, items} ->
      categories = 
        items 
        |> Enum.group_by(fn i -> i.parent_name || i.category_name end)
        |> Enum.map(fn {name, txs} -> 
          %{name: name, total: txs |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.total)) |> Decimal.abs()}
        end)
      
      %{year: year, month: month, categories: categories}
    end)
    |> Enum.sort_by(fn %{year: y, month: m} -> {y, m} end)
  end

  defp get_latest_transaction_date do
    Repo.one(from t in Transaction, select: max(t.date))
  end

  @doc """
  Gets a single transaction.
  """
  def get_transaction!(id), do: Repo.get!(Transaction, id) |> Repo.preload([:category, :account])

  @doc """
  Creates a transaction.
  """
  def create_transaction(attrs) do
    changeset = Transaction.changeset(%Transaction{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :fingerprint) do
      {:ok, %Transaction{id: nil}} -> {:ok, :duplicate}
      {:ok, transaction} -> 
        CashLens.Transactions.TransferMatcher.match_transfer(transaction)
        {:ok, transaction}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Updates a transaction.
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
    transaction |> Ecto.Changeset.change(category_id: category_id) |> Repo.update()
  end

  @doc """
  Deletes a transaction.
  """
  def delete_transaction(%Transaction{} = transaction), do: Repo.delete(transaction)

  @doc """
  Deletes all transactions from the database.
  """
  def delete_all_transactions, do: Repo.delete_all(Transaction)

  @doc """
  Reapplies auto-categorization rules to all transactions without a category.
  """
  def reapply_auto_categorization do
    query = from t in Transaction, where: is_nil(t.category_id)
    pending_transactions = Repo.all(query)

    Enum.each(pending_transactions, fn tx ->
      updates = CashLens.Transactions.AutoCategorizer.categorize(tx)
      if updates.category_id, do: update_transaction_category(tx.id, updates.category_id)
    end)

    :ok
  end

  def change_transaction(%Transaction{} = transaction, attrs \\ %{}), do: Transaction.changeset(transaction, attrs)
end
