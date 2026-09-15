defmodule CashLensWeb.PageController do
  use CashLensWeb, :controller

  alias CashLens.Accounting
  alias CashLens.Accounts
  alias CashLens.Pluggy.LivePreview
  alias CashLens.Pluggy.LivePreviewCache
  alias CashLens.Transactions

  @history_months 12

  def home(conn, _params) do
    # Get all accounts
    all_accounts = Accounts.list_accounts()

    # Get latest balances per account (triggers read-time self-healing check internally)
    latest_balances = Accounting.list_latest_balances()

    # Real history only: the last 12 months up to and including the current one.
    today = Date.utc_today()
    {start_m, start_y} = calculate_start_period(today, @history_months - 1)

    historical_balances = Accounting.get_historical_balances(limit: 24)
    historical_summary = Transactions.get_historical_summary(limit: 24)

    historical =
      generate_historical_series(start_y, start_m, historical_balances, historical_summary)

    chart_data = Jason.encode!(historical)

    # A linked account's Pluggy-reported balance, when available, is more
    # trustworthy than "persisted balance + estimated live-transaction
    # delta" — it's the bank's own real number, not an approximation that
    # can miss transactions our own fetch doesn't see (a real gap found
    # earlier: a PIX present in the bank's own export but absent from
    # Pluggy's transaction API). Only accounts with a stored `pluggy_balance`
    # use it; everything else keeps today's calculation.
    pluggy_balance_by_account_id =
      CashLens.Pluggy.list_linked_account_links()
      |> Enum.reject(&is_nil(&1.pluggy_balance))
      |> Map.new(&{&1.account_id, &1.pluggy_balance})

    # Credit card and closed accounts are excluded from the dashboard listing.
    accounts_with_data =
      all_accounts
      |> Enum.reject(&(&1.is_credit_card or &1.is_closed))
      |> Enum.map(fn account ->
        balance = Enum.find(latest_balances, &(&1.account_id == account.id))
        pluggy_balance = Map.get(pluggy_balance_by_account_id, account.id)

        %{
          id: account.id,
          name: account.name,
          bank: account.bank,
          color: account.color,
          icon: account.icon,
          uses_pluggy_balance?: not is_nil(pluggy_balance),
          display_balance:
            pluggy_balance || if(balance, do: balance.final_balance, else: account.balance)
        }
      end)

    # "Saldo Atual" excludes credit cards and closed accounts (already filtered out)
    total_balance =
      Enum.reduce(accounts_with_data, Decimal.new("0"), fn a, acc ->
        Decimal.add(acc, a.display_balance)
      end)

    # Live (unsaved) Pluggy entries bring "Saldo Atual" up to date with
    # activity since the last real import/sync — it only counts accounts
    # already reflected in `total_balance` above (no credit cards, no closed
    # accounts). Receitas/Despesas/Balanço, by contrast, reflect only
    # already-imported transactions: "Balanço" is derived directly from
    # Saldo Atual's own delta against the month's opening balance, so it
    # still captures live activity without a separate live income/expenses
    # tally that would double-count what Saldo Atual already shows.
    live_entries =
      safe_cache(fn -> live_preview_cache().get_all_entries() end, [])
      |> LivePreview.filter_temporary_entries()

    balance_account_ids = MapSet.new(accounts_with_data, & &1.id)

    # An account already using pluggy_balance directly (above) must not also
    # have its live entries added on top — pluggy_balance already reflects
    # the bank's current balance, so adding would double-count it.
    pluggy_balance_account_ids =
      accounts_with_data
      |> Enum.filter(& &1.uses_pluggy_balance?)
      |> MapSet.new(& &1.id)

    live_balance_entries =
      live_entries
      |> Enum.filter(&MapSet.member?(balance_account_ids, &1.account_id))
      |> Enum.reject(&MapSet.member?(pluggy_balance_account_ids, &1.account_id))

    current_total_balance = Decimal.add(total_balance, sum_amounts(live_balance_entries))

    summary = Transactions.get_monthly_summary()
    month_name = CashLensWeb.Formatters.month_name(summary.month.month)

    initial_balance_total =
      latest_balances
      |> Enum.filter(&MapSet.member?(balance_account_ids, &1.account_id))
      |> Enum.reduce(Decimal.new("0"), fn b, acc -> Decimal.add(acc, b.initial_balance) end)

    render(conn, :home,
      layout: {CashLensWeb.Layouts, :app},
      total_balance: current_total_balance,
      monthly_income: summary.income,
      monthly_expenses: summary.expenses,
      monthly_balance: Decimal.sub(current_total_balance, initial_balance_total),
      accounts: accounts_with_data,
      summary_month: month_name,
      chart_data: chart_data
    )
  end

  def chrome_devtools(conn, _params) do
    send_resp(conn, :no_content, "")
  end

  defp live_preview_cache,
    do: Application.get_env(:cash_lens, :pluggy_live_preview_cache, LivePreviewCache)

  # The cache is an optional, best-effort component (not started in `:test`).
  # If it isn't running, the dashboard must still render with plain DB
  # figures rather than crash.
  defp safe_cache(fun, default) do
    fun.()
  catch
    :exit, _reason -> default
  end

  defp sum_amounts(entries),
    do: Enum.reduce(entries, Decimal.new("0"), &Decimal.add(&2, &1.amount))

  defp calculate_start_period(date, months_back) do
    m = date.month - months_back
    if m <= 0, do: {m + 12, date.year - 1}, else: {m, date.year}
  end

  defp generate_historical_series(start_y, start_m, balances, summaries) do
    # Generate a list of {m, y} pairs for the range (exactly 12 months)
    periods =
      Enum.map(0..(@history_months - 1), fn i ->
        m = start_m + i
        y = start_y + div(m - 1, 12)
        {rem(m - 1, 12) + 1, y}
      end)

    Enum.map(periods, fn {m, y} ->
      hb = Enum.find(balances, &(&1.year == y and &1.month == m))

      summary =
        Enum.find(summaries, &(&1.year == y and &1.month == m)) ||
          %{income: Decimal.new("0"), expenses: Decimal.new("0"), balance: Decimal.new("0")}

      # Use previous month's final balance if current month has no data yet
      final_val = if hb, do: Decimal.to_float(hb.final_balance), else: 0.0

      %{
        year: y,
        month: m,
        final_balance: final_val,
        income: Decimal.to_float(summary.income),
        expenses: Decimal.to_float(summary.expenses),
        balance: Decimal.to_float(summary.balance)
      }
    end)
    # Fill in missing final_balances by carrying forward
    |> Enum.reduce([], fn item, acc ->
      if item.final_balance == 0.0 and acc != [] do
        last = List.last(acc)
        acc ++ [%{item | final_balance: last.final_balance}]
      else
        acc ++ [item]
      end
    end)
  end
end
