defmodule CashLensWeb.PageController do
  use CashLensWeb, :controller

  alias CashLens.Accounting
  alias CashLens.CreditCards
  alias CashLens.Accounts
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
          display_balance: if(balance, do: balance.final_balance, else: account.balance)
        }
      end)

    # "Saldo Atual" excludes credit cards and closed accounts (already filtered out)
    total_balance =
      Enum.reduce(accounts_with_data, Decimal.new("0"), fn a, acc ->
        Decimal.add(acc, a.display_balance)
      end)

    summary = Transactions.get_monthly_summary()
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
      monthly_balance: Decimal.sub(total_balance, initial_balance_total),
      accounts: accounts_with_data,
      summary_month: month_name,
      chart_data: chart_data,
      historical: historical,
      closed_statements: CreditCards.closed_without_statement(),
      payable: CreditCards.payable_statements(CreditCards.list_statements()),
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
