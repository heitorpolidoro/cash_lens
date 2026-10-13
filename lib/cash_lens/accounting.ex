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
    :telemetry.span(
      [:cash_lens, :accounting, :calculate_balance],
      %{account_id: account_id, year: year, month: month},
      fn ->
        result = do_calculate_monthly_balance(account_id, year, month)
        status = if(match?({:ok, _}, result), do: :success, else: :error)
        {result, %{status: status}}
      end
    )
  end

  defp do_calculate_monthly_balance(account_id, year, month) do
    first_of_month = Date.new!(year, month, 1)
    last_of_month = Date.end_of_month(first_of_month)

    # Check if we are updating an existing balance
    existing_balance = Repo.get_by(Balance, account_id: account_id, year: year, month: month)

    # 1. Get transactions for the specific month (with category to detect transfers)
    query =
      from t in Transaction,
        where: t.account_id == ^account_id,
        where: t.date >= ^first_of_month and t.date <= ^last_of_month,
        preload: [:category]

    transactions = Repo.all(query)

    # Split real movements from transfers (category "transfer"). Transfers just move
    # money between the user's own accounts, so they are tracked separately from real
    # income/expenses while still affecting the account's final balance.
    {transfers, real} = Enum.split_with(transactions, &transfer?/1)

    income = sum_positive(real)
    expenses = real |> sum_negative() |> Decimal.abs()
    transfers_in = sum_positive(transfers)
    transfers_out = transfers |> sum_negative() |> Decimal.abs()

    # 2. Get initial balance (Chained from previous month or last snapshot)
    initial_balance =
      get_chained_initial_balance(account_id, year, month, first_of_month, existing_balance)

    # 3. Final calculations — balance moves with real income/expenses AND transfers.
    balance_diff =
      income
      |> Decimal.sub(expenses)
      |> Decimal.add(transfers_in)
      |> Decimal.sub(transfers_out)

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
      transfers_in: transfers_in,
      transfers_out: transfers_out,
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

  defp transfer?(%{category: %{slug: "transfer"}}), do: true
  defp transfer?(_), do: false

  defp sum_positive(transactions) do
    transactions
    |> Enum.filter(&Decimal.gt?(&1.amount, 0))
    |> Enum.reduce(Decimal.new("0"), fn t, acc -> Decimal.add(acc, t.amount) end)
  end

  defp sum_negative(transactions) do
    transactions
    |> Enum.filter(&Decimal.lt?(&1.amount, 0))
    |> Enum.reduce(Decimal.new("0"), fn t, acc -> Decimal.add(acc, t.amount) end)
  end

  defp get_chained_initial_balance(account_id, year, month, first_of_month, existing_balance) do
    {prev_year, prev_month} = get_previous_period(year, month)

    case Repo.get_by(Balance, account_id: account_id, year: prev_year, month: prev_month) do
      %Balance{final_balance: final} ->
        Logger.debug("Chaining balance: Using final balance from #{prev_month}/#{prev_year}")
        final

      nil ->
        handle_initial_balance_fallback(account_id, year, month, first_of_month, existing_balance)
    end
  end

  defp handle_initial_balance_fallback(account_id, year, month, first_of_month, existing_balance) do
    case find_latest_balance_before(account_id, year, month) do
      %Balance{} = last_balance ->
        calculate_from_point(account_id, last_balance, year, month)

      nil ->
        resolve_root_or_base_balance(account_id, first_of_month, existing_balance)
    end
  end

  defp find_latest_balance_before(account_id, year, month) do
    Balance
    |> where([b], b.account_id == ^account_id)
    |> where([b], b.year < ^year or (b.year == ^year and b.month < ^month))
    |> order_by([b], desc: b.year, desc: b.month)
    |> limit(1)
    |> Repo.one()
  end

  defp resolve_root_or_base_balance(account_id, first_of_month, existing_balance) do
    if existing_balance do
      Logger.debug("Root balance detected. Preserving existing initial_balance.")
      existing_balance.initial_balance
    else
      Logger.info("Using account base balance + previous transactions.")
      calculate_base_plus_previous(account_id, first_of_month)
    end
  end

  defp calculate_base_plus_previous(account_id, first_of_month) do
    base_balance =
      Repo.one(
        from a in CashLens.Accounts.Account,
          where: a.id == ^account_id,
          select: a.balance
      ) || Decimal.new("0")

    initial_query =
      from t in Transaction,
        where: t.account_id == ^account_id and t.date < ^first_of_month,
        select: sum(t.amount)

    previous_transactions_sum = Repo.one(initial_query) || Decimal.new("0")

    Decimal.add(base_balance, previous_transactions_sum)
  end

  @doc false
  def __test_calculate_from_point(account_id, last_point, target_year, target_month),
    do: calculate_from_point(account_id, last_point, target_year, target_month)

  defp calculate_from_point(account_id, last_point, target_year, target_month) do
    if {last_point.year, last_point.month} >= {target_year, target_month} do
      last_point.final_balance
    else
      {next_year, next_month} = get_next_period(last_point.year, last_point.month)

      # We recursively calculate all missing months between the last point and our target
      # This ensures that even if we are missing a whole year, the chain is restored.
      case calculate_monthly_balance(account_id, next_year, next_month) do
        {:ok, next_balance} ->
          continue_from_point(account_id, next_balance, target_year, target_month)

        {:error, reason} ->
          Logger.error(
            "Failed to re-calculate balance chain at #{next_month}/#{next_year}: #{inspect(reason)}"
          )

          # Fallback to the last known point to avoid complete failure
          last_point.final_balance
      end
    end
  end

  defp continue_from_point(account_id, point, target_year, target_month) do
    if {point.year, point.month} == {target_year, target_month} do
      point.final_balance
    else
      calculate_from_point(account_id, point, target_year, target_month)
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
  Rebuilds all Balance records for an account from scratch by deleting every existing
  Balance and recalculating month by month in chronological order, seeding from the
  current `account.balance` value.

  This must be called whenever the account's initial balance (seed value) changes, as
  `recalculate_all_balances/0` would otherwise preserve the stale root `initial_balance`.

  If the account has no transactions the function is a no-op — no Balance records are created.
  """
  def rebuild_account_balances(account_id) do
    Repo.delete_all(from b in Balance, where: b.account_id == ^account_id)

    # Get the account to check if it is closed
    account = CashLens.Accounts.get_account!(CashLens.Ownership.current_user!(), account_id)

    # Find the oldest transaction for this account
    oldest_tx =
      Repo.one(
        from t in Transaction,
          where: t.account_id == ^account_id,
          order_by: [asc: t.date],
          limit: 1
      )

    {start_year, start_month} = rebuild_start_period(account, oldest_tx)
    {end_year, end_month} = rebuild_end_period(account, {start_year, start_month})

    # Calculate the first month's balance
    case calculate_monthly_balance(account_id, start_year, start_month) do
      {:ok, first_balance} ->
        # Propagate forward up to the end month/year
        if {start_year, start_month} != {end_year, end_month} do
          calculate_from_point(account_id, first_balance, end_year, end_month)
        end

        :ok

      _error ->
        :ok
    end
  end

  # The first month to rebuild: the oldest transaction's, else the account's creation.
  defp rebuild_start_period(account, nil) do
    inserted_date = DateTime.to_date(account.inserted_at || DateTime.utc_now())
    {inserted_date.year, inserted_date.month}
  end

  defp rebuild_start_period(_account, tx), do: {tx.date.year, tx.date.month}

  # The last month to rebuild: the current month, or the newest transaction's when
  # the account is closed. Never earlier than the start.
  defp rebuild_end_period(account, start_period) do
    end_period =
      if account.is_closed do
        newest_tx =
          Repo.one(
            from t in Transaction,
              where: t.account_id == ^account.id,
              order_by: [desc: t.date],
              limit: 1
          )

        case newest_tx do
          nil -> start_period
          tx -> {tx.date.year, tx.date.month}
        end
      else
        today = Date.utc_today()
        {today.year, today.month}
      end

    max(end_period, start_period)
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
  def list_latest_balances(opts \\ []) do
    if Keyword.get(opts, :heal, true), do: heal_active_balances()

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
            fragment("(? * 100 + ?)", b.year, b.month) == s.latest_date

    case Keyword.get(opts, :accounts) do
      nil ->
        Repo.all(from b in query, preload: [:account])

      accounts ->
        # The caller already holds the accounts: attach them instead of
        # preloading, which would read the `accounts` table again.
        by_id = Map.new(accounts, &{&1.id, &1})
        query |> Repo.all() |> Enum.map(&%{&1 | account: Map.get(by_id, &1.account_id)})
    end
  end

  @doc """
  Returns aggregated balance history grouped by year and month.
  """
  def get_historical_balances(opts \\ []) do
    if Keyword.get(opts, :heal, true), do: heal_active_balances()

    limit = Keyword.get(opts, :limit)

    # final_balance feeds the dashboard's "Saldo Atual" card/chart line, which
    # excludes credit card accounts (their balance is a debt, not cash on hand) —
    # so its sum zeroes out credit card rows while every other aggregate keeps
    # summing all accounts.
    query =
      from b in Balance,
        join: a in assoc(b, :account),
        group_by: [b.year, b.month],
        select: %{
          year: b.year,
          month: b.month,
          income: sum(b.income),
          expenses: sum(b.expenses),
          transfers_in: sum(b.transfers_in),
          transfers_out: sum(b.transfers_out),
          balance: sum(b.balance),
          final_balance:
            sum(fragment("CASE WHEN ? THEN 0 ELSE ? END", a.is_credit_card, b.final_balance))
        }

    query =
      if limit do
        query
        |> order_by([b], desc: b.year, desc: b.month)
        |> limit(^limit)
      else
        query
        |> order_by([b], asc: b.year, asc: b.month)
      end

    res = Repo.all(query)

    if limit do
      Enum.sort_by(res, &{&1.year, &1.month})
    else
      res
    end
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

  @doc """
  Rebuilds the balance chain of every open account that has no balance row for
  the current month. One set-based query finds them, so the cost does not grow
  with the number of accounts; closed accounts are ignored.

  `list_latest_balances/1` and `get_historical_balances/1` run this themselves;
  a caller that already ran it passes `heal: false` to skip the repeat.
  """
  def heal_active_balances do
    today = Date.utc_today()

    missing_ids =
      Repo.all(
        from a in CashLens.Accounts.Account,
          as: :account,
          where: a.is_closed == false,
          where:
            not exists(
              from b in Balance,
                where:
                  b.account_id == parent_as(:account).id and b.year == ^today.year and
                    b.month == ^today.month,
                select: 1
            ),
          select: a.id
      )

    Enum.each(missing_ids, &rebuild_account_balances/1)
  end
end
