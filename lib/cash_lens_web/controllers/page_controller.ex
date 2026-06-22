defmodule CashLensWeb.PageController do
  use CashLensWeb, :controller

  alias CashLens.Accounting
  alias CashLens.Accounts
  alias CashLens.Transactions

  def home(conn, _params) do
    # Get all accounts
    all_accounts = Accounts.list_accounts()

    # Get latest balances per account (triggers read-time self-healing check internally)
    latest_balances = Accounting.list_latest_balances()

    # Get historical data for the chart (ensure we have 12 months of history)
    today = Date.utc_today()
    {start_m, start_y} = calculate_start_period(today, 11)

    historical_balances = Accounting.get_historical_balances(limit: 24)
    historical_summary = Transactions.get_historical_summary(limit: 24)

    historical =
      generate_historical_series(
        start_y,
        start_m,
        today.year,
        today.month,
        historical_balances,
        historical_summary
      )

    # 1. Calculate Averages (past 12 months)
    {avg_income, avg_expenses} = calculate_averages(historical_summary)

    # 2. Get active installment groups to factor into projections
    active_groups = CashLens.Installments.list_installment_groups()

    # 3. Generate 6 Projection Months
    # coveralls-ignore-start — the historical series is always non-empty, so the
    # fallback map is a defensive default that never executes in practice.
    last_real =
      List.last(historical) ||
        %{final_balance: 0.0, year: Date.utc_today().year, month: Date.utc_today().month}

    # coveralls-ignore-stop

    projections = generate_projections(last_real, avg_income, avg_expenses, active_groups, 6)

    chart_data = Jason.encode!(historical ++ projections)

    # Map accounts to their latest data (Balance final_balance or Account balance)
    accounts_with_data =
      Enum.map(all_accounts, fn account ->
        balance = Enum.find(latest_balances, &(&1.account_id == account.id))

        %{
          id: account.id,
          name: account.name,
          bank: account.bank,
          color: account.color,
          icon: account.icon,
          is_closed: account.is_closed,
          is_credit_card: account.is_credit_card,
          display_balance: if(balance, do: balance.final_balance, else: account.balance)
        }
      end)

    # "Saldo Atual" excludes credit cards: their balance is a debt, not cash on hand.
    total_balance =
      accounts_with_data
      |> Enum.reject(&(&1.is_closed or &1.is_credit_card))
      |> Enum.reduce(Decimal.new("0"), fn a, acc -> Decimal.add(acc, a.display_balance) end)

    total_balance_with_credit_cards =
      accounts_with_data
      |> Enum.reject(& &1.is_closed)
      |> Enum.reduce(Decimal.new("0"), fn a, acc -> Decimal.add(acc, a.display_balance) end)

    summary = Transactions.get_monthly_summary()
    historical_categories = Transactions.get_historical_category_summary(limit: 12)

    fixed_data = extract_category_data(historical_categories, "fixed")
    variable_data = extract_category_data(historical_categories, "variable")

    month_name = CashLensWeb.Formatters.month_name(summary.month.month)

    render(conn, :home,
      layout: {CashLensWeb.Layouts, :app},
      total_balance: total_balance,
      total_balance_with_credit_cards: total_balance_with_credit_cards,
      monthly_income: summary.income,
      monthly_expenses: summary.expenses,
      accounts: accounts_with_data,
      summary_month: month_name,
      chart_data: chart_data,
      fixed_data: fixed_data,
      variable_data: variable_data,
      historical: historical
    )
  end

  def chrome_devtools(conn, _params) do
    send_resp(conn, :no_content, "")
  end

  defp extract_category_data(historical_categories, type) do
    historical_categories
    |> Enum.map(&filter_and_format_categories(&1, type))
    |> Jason.encode!()
  end

  defp filter_and_format_categories(month_data, type) do
    Map.update!(month_data, :categories, fn categories ->
      categories
      |> Enum.filter(&(&1.type == type))
      |> Enum.map(fn cat -> Map.put(cat, :total, Decimal.to_float(cat.total)) end)
    end)
  end

  defp calculate_start_period(date, months_back) do
    m = date.month - months_back
    if m <= 0, do: {m + 12, date.year - 1}, else: {m, date.year}
  end

  defp generate_historical_series(start_y, start_m, _end_y, _end_m, balances, summaries) do
    # Generate a list of {m, y} pairs for the range (exactly 12 months)
    periods =
      Enum.reduce(0..11, [], fn i, acc ->
        m = start_m + i
        y = start_y + div(m - 1, 12)
        m = rem(m - 1, 12) + 1
        acc ++ [{m, y}]
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
        balance: Decimal.to_float(summary.balance),
        is_projection: false
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

  defp calculate_averages([]), do: {0.0, 0.0}

  defp calculate_averages(summary) do
    count = length(summary)
    total_income = Enum.reduce(summary, 0.0, fn s, acc -> acc + Decimal.to_float(s.income) end)

    total_expenses =
      Enum.reduce(summary, 0.0, fn s, acc -> acc + Decimal.to_float(s.expenses) end)

    {total_income / count, total_expenses / count}
  end

  defp generate_projections(last_real, avg_income, avg_expenses, active_groups, count) do
    Enum.reduce(1..count, {[], last_real}, fn _, {acc_proj, last} ->
      {next_m, next_y} =
        if last.month == 12, do: {1, last.year + 1}, else: {last.month + 1, last.year}

      # Factor in installments for this specific future month
      installment_impact = installment_impact_for(active_groups, next_y, next_m)

      proj_expenses = avg_expenses + installment_impact
      proj_balance = avg_income - proj_expenses
      proj_final = last.final_balance + proj_balance

      new_proj = %{
        year: next_y,
        month: next_m,
        final_balance: proj_final,
        income: avg_income,
        expenses: proj_expenses,
        balance: proj_balance,
        is_projection: true
      }

      {acc_proj ++ [new_proj], new_proj}
    end)
    |> elem(0)
  end

  # Projected installment burden for a given future month: assumes one installment
  # is paid per month, counting only groups still active in that month.
  defp installment_impact_for(active_groups, year, month) do
    active_groups
    |> Enum.filter(&group_active_in_month?(&1, year, month))
    |> Enum.reduce(0.0, fn group, sum -> sum + group_installment_value(group) end)
  end

  defp group_active_in_month?(group, year, month) do
    months_since_start =
      (year - group.start_date.year) * 12 + (month - group.start_date.month)

    months_since_start >= 0 and months_since_start < group.installments
  end

  defp group_installment_value(%{total_amount: nil}), do: 0.0

  defp group_installment_value(%{total_amount: total, installments: count}),
    do: Decimal.to_float(total) / count
end
