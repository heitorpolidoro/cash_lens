defmodule CashLensWeb.PageController do
  use CashLensWeb, :controller

  alias CashLens.Accounting
  alias CashLens.Accounts
  alias CashLens.Transactions

  def home(conn, _params) do
    # Get latest balances per account
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
    last_real =
      List.last(historical) ||
        %{final_balance: 0.0, year: Date.utc_today().year, month: Date.utc_today().month}

    projections = generate_projections(last_real, avg_income, avg_expenses, active_groups, 6)

    chart_data = Jason.encode!(historical ++ projections)

    # Get all accounts to find those without a balance yet
    all_accounts = Accounts.list_accounts()

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
          display_balance: if(balance, do: balance.final_balance, else: account.balance)
        }
      end)

    total_balance =
      accounts_with_data
      |> Enum.reduce(Decimal.new("0"), fn a, acc -> Decimal.add(acc, a.display_balance) end)

    summary = Transactions.get_monthly_summary()
    historical_categories = Transactions.get_historical_category_summary(limit: 12)

    fixed_data = extract_category_data(historical_categories, "fixed")
    variable_data = extract_category_data(historical_categories, "variable")

    month_name =
      summary.month
      |> Calendar.strftime("%B")
      |> translate_month()

    render(conn, :home,
      layout: {CashLensWeb.Layouts, :app},
      total_balance: total_balance,
      monthly_income: summary.income,
      monthly_expenses: summary.expenses,
      accounts: accounts_with_data,
      summary_month: month_name,
      chart_data: chart_data,
      fixed_data: fixed_data,
      variable_data: variable_data
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

  defp translate_month(month) do
    months = %{
      "January" => "Janeiro",
      "February" => "Fevereiro",
      "March" => "Março",
      "April" => "Abril",
      "May" => "Maio",
      "June" => "Junho",
      "July" => "Julho",
      "August" => "Agosto",
      "September" => "Setembro",
      "October" => "Outubro",
      "November" => "Novembro",
      "December" => "Dezembro"
    }

    months[month] || month
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
      # We check how many installments are ALREADY paid to see what's remaining.
      # For projection, we assume 1 installment is paid per month starting from next month.
      installment_impact =
        Enum.reduce(active_groups, 0.0, fn group, sum ->
          _progress = CashLens.Installments.get_group_with_progress(group.id)

          # Simplified: if it started before or on this month and isn't finished.
          # We check month proximity relative to 'last_real'
          months_since_start =
            (next_y - group.start_date.year) * 12 + (next_m - group.start_date.month)

          if months_since_start >= 0 and months_since_start < group.installments do
            # It's an active month for this group
            installment_val = Decimal.to_float(group.total_amount) / group.installments
            sum + installment_val
          else
            sum
          end
        end)

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
end
