defmodule CashLensWeb.DashboardLimitTest do
  use CashLensWeb.ConnCase

  alias CashLens.Accounting
  alias CashLens.Transactions
  import CashLens.AccountsFixtures
  import CashLens.AccountingFixtures
  import CashLens.TransactionsFixtures

  describe "dashboard data limiting" do
    setup do
      account = account_fixture()

      # Create 15 months of data: 2025-01 to 2026-03
      for year <- 2025..2026, month <- 1..12 do
        if year == 2025 or (year == 2026 and month <= 3) do
          balance_fixture(%{
            account_id: account.id,
            year: year,
            month: month,
            final_balance: "100.00"
          })

          transaction_fixture(%{
            account_id: account.id,
            amount: "50.00",
            date: Date.new!(year, month, 1)
          })
        end
      end

      %{account: account}
    end

    test "Accounting.get_historical_balances limits to 12 months" do
      results = Accounting.get_historical_balances(limit: 12)
      assert length(results) == 12

      # Should be the most recent 12: 2025-04 to 2026-03
      first = List.first(results)
      last = List.last(results)

      assert first.year == 2025
      assert first.month == 4
      assert last.year == 2026
      assert last.month == 3
    end

    test "Transactions.get_historical_summary limits to 12 months" do
      results = Transactions.get_historical_summary(limit: 12)
      assert length(results) == 12

      first = List.first(results)
      last = List.last(results)

      assert first.year == 2025
      assert first.month == 4
      assert last.year == 2026
      assert last.month == 3
    end

    test "GET / returns 200 and renders dashboard", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Dashboard"
    end
  end
end
