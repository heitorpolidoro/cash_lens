defmodule CashLensWeb.PageController do
  use CashLensWeb, :controller

  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLens.Accounting

  def home(conn, _params) do
    # Get latest balances per account
    latest_balances = Accounting.list_latest_balances()
    
    # Get historical data for the chart
    historical_balances = Accounting.get_historical_balances()
    historical_summary = Transactions.get_historical_summary()

    historical = Enum.map(historical_balances, fn hb ->
      summary = Enum.find(historical_summary, &(&1.year == hb.year and &1.month == hb.month)) || %{income: 0, expenses: 0, balance: 0}
      %{
        year: hb.year,
        month: hb.month,
        final_balance: hb.final_balance,
        income: summary.income,
        expenses: summary.expenses,
        balance: summary.balance
      }
    end)
    
    chart_data = Jason.encode!(historical)
    
    # Get all accounts to find those without a balance yet
    all_accounts = Accounts.list_accounts()
    
    # Map accounts to their latest data (Balance final_balance or Account balance)
    accounts_with_data = Enum.map(all_accounts, fn account ->
      balance = Enum.find(latest_balances, &(&1.account_id == account.id))
      
      %{
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
    historical_categories = Transactions.get_historical_category_summary()
    category_data = Jason.encode!(historical_categories)

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
      category_data: category_data
    )
  end

  defp translate_month(month) do
    months = %{
      "January" => "Janeiro", "February" => "Fevereiro", "March" => "Março",
      "April" => "Abril", "May" => "Maio", "June" => "Junho",
      "July" => "Julho", "August" => "Agosto", "September" => "Setembro",
      "October" => "Outubro", "November" => "Novembro", "December" => "Dezembro"
    }
    months[month] || month
  end
end
