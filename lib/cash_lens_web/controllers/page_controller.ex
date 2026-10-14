defmodule CashLensWeb.PageController do
  use CashLensWeb, :controller

  alias CashLens.Accounting
  alias CashLens.Accounts
  alias CashLens.CreditCards
  alias CashLens.Forecast
  alias CashLens.Transactions
  alias CashLensWeb.BankruptcyCard

  @history_months 12

  # The same 12-month window the forecast screen projects over, so the card says
  # the same thing on both.
  @forecast_horizon_days 365

  def home(conn, _params) do
    user = conn.assigns.current_user

    # Accounts and latest balances are read once and handed down: the forecast
    # would otherwise read both again. `list_latest_balances/1` is also where
    # the read-time self-healing probe runs, so it runs once per request.
    all_accounts = Accounts.list_accounts(conn.assigns.current_user)

    latest_balances =
      Accounting.list_latest_balances(conn.assigns.current_user, accounts: all_accounts)

    # One projection serves both the bill list and the bankruptcy card: a
    # 30-day slice of a 365-day projection is the same slice, so building two
    # would only cost twice.
    projection =
      Forecast.project(@forecast_horizon_days, Date.utc_today(),
        accounts: all_accounts,
        latest_balances: latest_balances
      )

    # Resolved once and handed to every summary read: the answer is the same
    # within a request, and it is not kept past it.
    summary_opts = [excluded_category_ids: Transactions.summary_excluded_category_ids(user)]

    # Real history only: the last 12 months up to and including the current one.
    today = Date.utc_today()
    {start_m, start_y} = calculate_start_period(today, @history_months - 1)

    historical_balances =
      Accounting.get_historical_balances(conn.assigns.current_user, limit: 24, heal: false)

    historical_summary = Transactions.get_historical_summary(user, [{:limit, 24} | summary_opts])

    historical =
      generate_historical_series(start_y, start_m, historical_balances, historical_summary)

    chart_data = Jason.encode!(historical)

    # Credit card and closed accounts are excluded from the dashboard listing.
    accounts_with_data =
      all_accounts
      |> Enum.reject(&(&1.is_credit_card or &1.is_closed))
      |> Enum.map(fn account ->
        balance = Enum.find(latest_balances, &(&1.account_id == account.id))

        %{
          id: account.id,
          name: account.name,
          bank: account.bank,
          color: account.color,
          icon: account.icon,
          is_investment: account.is_investment,
          display_balance: if(balance, do: balance.final_balance, else: account.balance)
        }
      end)

    # "Saldo Atual" excludes credit cards and closed accounts (already filtered out)
    total_balance =
      Enum.reduce(accounts_with_data, Decimal.new("0"), fn a, acc ->
        Decimal.add(acc, a.display_balance)
      end)

    summary = Transactions.get_monthly_summary(user, nil, %{}, summary_opts)
    month_name = CashLensWeb.Formatters.month_name(summary.month.month)

    balance_account_ids = MapSet.new(accounts_with_data, & &1.id)

    initial_balance_total =
      latest_balances
      |> Enum.filter(&MapSet.member?(balance_account_ids, &1.account_id))
      |> Enum.reduce(Decimal.new("0"), fn b, acc -> Decimal.add(acc, b.initial_balance) end)

    render(conn, :home,
      layout: {CashLensWeb.Layouts, :app},
      total_balance: total_balance,
      monthly_income: summary.income,
      monthly_expenses: summary.expenses,
      spend_rate:
        Transactions.spend_rate(user, summary.month, summary.expenses, today, summary_opts),
      monthly_balance: Decimal.sub(total_balance, initial_balance_total),
      accounts: accounts_with_data,
      summary_month: month_name,
      chart_data: chart_data,
      historical: historical,
      closed_statements: CreditCards.closed_without_statement(user),
      upcoming: Forecast.upcoming_bills(projection),
      bankruptcy_card: BankruptcyCard.assigns_from(projection, @forecast_horizon_days),
      today: Date.utc_today()
    )
  end

  def chrome_devtools(conn, _params) do
    send_resp(conn, :no_content, "")
  end

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
