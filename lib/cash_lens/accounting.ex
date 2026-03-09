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

    # Check if we are updating an existing balance
    existing_balance = Repo.get_by(Balance, account_id: account_id, year: year, month: month)

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

    # 2. Get initial balance (Priority: Previous month final balance > Existing root initial balance > Transactions sum)
    initial_balance = get_chained_initial_balance(account_id, year, month, first_of_month, existing_balance)
    
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
    case existing_balance do
      nil -> create_balance(attrs)
      balance -> update_balance(balance, attrs)
    end
  end

  defp get_chained_initial_balance(account_id, year, month, first_of_month, existing_balance) do
    {prev_year, prev_month} = get_previous_period(year, month)

    case Repo.get_by(Balance, account_id: account_id, year: prev_year, month: prev_month) do
      %Balance{final_balance: final} -> 
        IO.puts("Chaining balance: Using final balance from #{prev_month}/#{prev_year} as initial for #{month}/#{year}")
        final
      
      nil -> 
        if existing_balance do
          IO.puts("Root balance detected. Preserving existing initial_balance.")
          existing_balance.initial_balance
        else
          # Fallback to the Account's base balance PLUS the sum of any transactions before this month
          IO.puts("No previous balance found for #{prev_month}/#{prev_year}. Using account base balance + previous transactions.")
          
          account = Repo.get!(CashLens.Accounts.Account, account_id)
          base_balance = account.balance || Decimal.new("0")

          initial_query = from t in Transaction,
            where: t.account_id == ^account_id and t.date < ^first_of_month,
            select: sum(t.amount)
          
          previous_transactions_sum = Repo.one(initial_query) || Decimal.new("0")
          
          Decimal.add(base_balance, previous_transactions_sum)
        end
    end
  end

  defp get_previous_period(year, 1), do: {year - 1, 12}
  defp get_previous_period(year, month), do: {year, month - 1}

  @doc """
  Returns the list of all balances based on filters and pagination.
  """
  def list_balances(filters \\ %{}, page \\ 1, page_size \\ 20) do
    offset = (page - 1) * page_size

    Balance
    |> filter_by_account(filters["account_id"])
    |> filter_by_month(filters["month"])
    |> filter_by_year(filters["year"])
    |> order_by([b], desc: b.year, desc: b.month)
    |> preload([:account])
    |> limit(^page_size)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Recalculates all existing balances in chronological order to ensure chained initial balances propagate correctly.
  """
  def recalculate_all_balances do
    balances = 
      Balance
      |> order_by([b], asc: b.year, asc: b.month)
      |> select([b], %{account_id: b.account_id, year: b.year, month: b.month})
      |> Repo.all()

    Enum.each(balances, fn %{account_id: acc_id, year: year, month: month} ->
      calculate_monthly_balance(acc_id, year, month)
    end)
    
    :ok
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

  @doc """
  Returns aggregated balance history grouped by year and month.
  """
  def get_historical_balances do
    query = from b in Balance,
      group_by: [b.year, b.month],
      order_by: [asc: b.year, asc: b.month],
      select: %{
        year: b.year,
        month: b.month,
        income: sum(b.income),
        expenses: sum(b.expenses),
        balance: sum(b.balance),
        final_balance: sum(b.final_balance)
      }

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
