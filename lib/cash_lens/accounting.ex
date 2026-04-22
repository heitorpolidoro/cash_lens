defmodule CashLens.Accounting do
  @moduledoc """
  The Accounting context.
  """

  import Ecto.Query, warn: false
  alias CashLens.Repo

  require Logger
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
    query =
      from t in Transaction,
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

    # 2. Get initial balance (Chained from previous month or last snapshot)
    initial_balance =
      get_chained_initial_balance(account_id, year, month, first_of_month, existing_balance)

    # 3. Final calculations
    balance_diff = Decimal.sub(income, expenses)
    final_balance = Decimal.add(initial_balance, balance_diff)

    # A snapshot is created every 6 months to avoid re-calculating from the beginning of time
    is_snapshot = rem(month, 6) == 0

    attrs = %{
      account_id: account_id,
      year: year,
      month: month,
      initial_balance: initial_balance,
      income: income,
      expenses: expenses,
      balance: balance_diff,
      final_balance: final_balance,
      is_snapshot: is_snapshot
    }

    # Atomic Upsert using the unique index
    Repo.insert(
      %Balance{} |> Balance.changeset(attrs),
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:account_id, :year, :month],
      returning: true
    )
  end

  defp get_chained_initial_balance(account_id, year, month, first_of_month, existing_balance) do
    {prev_year, prev_month} = get_previous_period(year, month)

    case Repo.get_by(Balance, account_id: account_id, year: prev_year, month: prev_month) do
      %Balance{final_balance: final} ->
        Logger.debug("Chaining balance: Using final balance from #{prev_month}/#{prev_year}")
        final

      nil ->
        # If no previous month, look for the most recent snapshot BEFORE this month
        last_snapshot =
          from(b in Balance,
            where: b.account_id == ^account_id and b.is_snapshot == true,
            where: fragment("(? * 100 + ?)", b.year, b.month) < ^(year * 100 + month),
            order_by: [desc: b.year, desc: b.month],
            limit: 1
          )
          |> Repo.one()

        cond do
          last_snapshot ->
            Logger.info(
              "Found snapshot at #{last_snapshot.month}/#{last_snapshot.year}. Re-calculating from there..."
            )

            calculate_from_point(account_id, last_snapshot, year, month)

          existing_balance ->
            Logger.debug("Root balance detected. Preserving existing initial_balance.")
            existing_balance.initial_balance

          true ->
            # Fallback to the Account's base balance PLUS the sum of any transactions before this month
            Logger.info(
              "No previous balance or snapshot. Using account base balance + previous transactions."
            )

            account = Repo.get!(CashLens.Accounts.Account, account_id)
            base_balance = account.balance || Decimal.new("0")

            initial_query =
              from t in Transaction,
                where: t.account_id == ^account_id and t.date < ^first_of_month,
                select: sum(t.amount)

            previous_transactions_sum = Repo.one(initial_query) || Decimal.new("0")

            Decimal.add(base_balance, previous_transactions_sum)
        end
    end
  end

  defp calculate_from_point(account_id, last_point, target_year, target_month) do
    {next_year, next_month} = get_next_period(last_point.year, last_point.month)

    # We recursively calculate all missing months between the last point and our target
    # This ensures that even if we are missing a whole year, the chain is restored.
    if {next_year, next_month} == {target_year, target_month} do
      last_point.final_balance
    else
      {:ok, next_balance} = calculate_monthly_balance(account_id, next_year, next_month)
      calculate_from_point(account_id, next_balance, target_year, target_month)
    end
  end

  defp get_previous_period(year, 1), do: {year - 1, 12}
  defp get_previous_period(year, month), do: {year, month - 1}

  defp get_next_period(year, 12), do: {year + 1, 1}
  defp get_next_period(year, month), do: {year, month + 1}

  @doc """
  Returns the most recent balance for a specific account.
  """
  def get_latest_balance_for_account(account_id) do
    Balance
    |> where(account_id: ^account_id)
    |> order_by([b], desc: b.year, desc: b.month)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns the oldest balance for a specific account.
  """
  def get_oldest_balance_for_account(account_id) do
    Balance
    |> where(account_id: ^account_id)
    |> order_by([b], asc: b.year, asc: b.month)
    |> limit(1)
    |> Repo.one()
  end

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
    subquery =
      from b in Balance,
        select: %{
          account_id: b.account_id,
          latest_date: max(fragment("(? * 100 + ?)", b.year, b.month))
        },
        group_by: b.account_id

    query =
      from b in Balance,
        join: s in subquery(subquery),
        on:
          b.account_id == s.account_id and
            fragment("(? * 100 + ?)", b.year, b.month) == s.latest_date,
        preload: [:account]

    Repo.all(query)
  end

  @doc """
  Returns aggregated balance history grouped by year and month.
  """
  def get_historical_balances do
    query =
      from b in Balance,
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
