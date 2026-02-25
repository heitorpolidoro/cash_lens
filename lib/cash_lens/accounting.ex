defmodule CashLens.Accounting do
  @moduledoc """
  The Accounting context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  alias CashLens.Accounting.Balance
  alias CashLens.Transactions.Transaction

  @doc """
  Calculates and creates/updates a monthly balance record for an account.
  """
  def calculate_monthly_balance(account_id, year, month) do
    first_of_month = Date.new!(year, month, 1)
    last_of_month = Date.end_of_month(first_of_month)

    # 1. Get transactions for the specific month
    query = from t in Transaction,
      left_join: c in assoc(t, :category),
      where: t.account_id == ^account_id,
      where: t.date >= ^first_of_month and t.date <= ^last_of_month,
      where: is_nil(c.slug) or c.slug not in ["initial_value", "transfer"]

    transactions = Repo.all(query)

    income = 
      transactions 
      |> Enum.filter(fn t -> Decimal.gt?(t.amount, 0) end)
      |> Enum.reduce(Decimal.new("0"), fn t, acc -> Decimal.add(acc, t.amount) end)

    expenses = 
      transactions 
      |> Enum.filter(fn t -> Decimal.lt?(t.amount, 0) end)
      |> Enum.reduce(Decimal.new("0"), fn t, acc -> Decimal.add(acc, t.amount) end)
      |> Decimal.abs()

    # 2. Get initial balance (simplified: sum of ALL transactions before this month)
    initial_query = from t in Transaction,
      where: t.account_id == ^account_id and t.date < ^first_of_month,
      select: sum(t.amount)
    
    initial_balance = Repo.one(initial_query) || Decimal.new("0")
    
    # 3. Final calculations
    balance_diff = Decimal.sub(income, expenses)
    final_balance = Decimal.add(initial_balance, balance_diff)

    attrs = %{
      account_id: account_id,
      year: year,
      month: month,
      initial_balance: initial_balance,
      income: income,
      expenses: expenses,
      balance: balance_diff,
      final_balance: final_balance
    }

    # Upsert logic (find existing or create new)
    case Repo.get_by(Balance, account_id: account_id, year: year, month: month) do
      nil -> create_balance(attrs)
      balance -> update_balance(balance, attrs)
    end
  end

  @doc """
  Returns the list of all balances.
  """
  def list_balances do
    Balance
    |> order_by([b], desc: b.year, desc: b.month)
    |> preload([:account])
    |> Repo.all()
  end

  @doc """
  Returns the most recent balance for each account.
  """
  def list_latest_balances do
    subquery = from b in Balance,
      select: %{account_id: b.account_id, latest_date: max(fragment("(? * 100 + ?)", b.year, b.month))},
      group_by: b.account_id

    query = from b in Balance,
      join: s in subquery(subquery),
      on: b.account_id == s.account_id and fragment("(? * 100 + ?)", b.year, b.month) == s.latest_date,
      preload: [:account]

    Repo.all(query)
  end

  def get_balance!(id), do: Repo.get!(Balance, id) |> Repo.preload(:account)

  def create_balance(attrs) do
    %Balance{}
    |> Balance.changeset(attrs)
    |> Repo.insert()
  end

  def update_balance(%Balance{} = balance, attrs) do
    balance
    |> Balance.changeset(attrs)
    |> Repo.update()
  end

  def delete_balance(%Balance{} = balance) do
    Repo.delete(balance)
  end

  def change_balance(%Balance{} = balance, attrs \\ %{}) do
    Balance.changeset(balance, attrs)
  end
end
