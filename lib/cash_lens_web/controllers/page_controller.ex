defmodule CashLensWeb.PageController do
  use CashLensWeb, :controller

  alias CashLens.Accounts
  alias CashLens.Transactions

  def home(conn, _params) do
    total_balance = Accounts.get_total_balance()
    summary = Transactions.get_monthly_summary()
    accounts = Accounts.list_accounts()
    recent_transactions = Transactions.list_recent_transactions(5)

    month_name = 
      summary.month 
      |> Calendar.strftime("%B") 
      |> translate_month()

    render(conn, :home, 
      layout: {CashLensWeb.Layouts, :app},
      total_balance: total_balance,
      monthly_income: summary.income,
      monthly_expenses: summary.expenses,
      accounts: accounts,
      recent_transactions: recent_transactions,
      summary_month: month_name
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
