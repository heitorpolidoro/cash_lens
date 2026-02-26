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
      where: t.account_id == ^account_id,
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
      |> Decimal.abs()

    # 2. Get initial balance (Priority: Previous month final balance > Transactions sum before month)
    initial_balance = get_chained_initial_balance(account_id, year, month, first_of_month)
    
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
  defp get_chained_initial_balance(account_id, year, month, first_of_month) do
    {prev_year, prev_month} = get_previous_period(year, month)

    case Repo.get_by(Balance, account_id: account_id, year: prev_year, month: prev_month) do
      %Balance{final_balance: final} -> 
        IO.puts("Chaining balance: Using final balance from #{prev_month}/#{prev_year} as initial for #{month}/#{year}")
        final
      
      nil -> 
        # Fallback to sum of transactions before this month
        IO.puts("No previous balance found for #{prev_month}/#{prev_year}. Falling back to transaction sum.")
        initial_query = from t in Transaction,
          where: t.account_id == ^account_id and t.date < ^first_of_month,
          select: sum(t.amount)
        
        Repo.one(initial_query) || Decimal.new("0")
    end
  end

  defp get_previous_period(year, 1), do: {year - 1, 12}
  defp get_previous_period(year, month), do: {year, month - 1}

  @doc """
  Returns the list of all balances based on filters.
  """
  def list_balances(filters \\ %{}) do
    Balance
    |> filter_by_account(filters["account_id"])
    |> filter_by_month(filters["month"])
    |> filter_by_year(filters["year"])
    |> order_by([b], desc: b.year, desc: b.month)
    |> preload([:account])
    |> Repo.all()
  end

  defp filter_by_account(query, nil), do: query
  defp filter_by_account(query, ""), do: query
  defp filter_by_account(query, account_id), do: where(query, account_id: ^account_id)

  defp filter_by_month(query, nil), do: query
  defp filter_by_month(query, ""), do: query
  defp filter_by_month(query, month), do: where(query, month: ^month)

  defp filter_by_year(query, nil), do: query
  defp filter_by_year(query, ""), do: query
  defp filter_by_year(query, year), do: where(query, year: ^year)

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
