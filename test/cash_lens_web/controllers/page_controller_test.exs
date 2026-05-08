defmodule CashLensWeb.PageControllerTest do
  use CashLensWeb.ConnCase

  import CashLens.AccountsFixtures
  import CashLens.AccountingFixtures
  import CashLens.TransactionsFixtures

  test "GET / with data", %{conn: conn} do
    account = account_fixture()
    balance_fixture(%{account_id: account.id, year: 2026, month: 4, final_balance: "500.00"})
    transaction_fixture(%{account_id: account.id, amount: "100.00", date: ~D[2026-04-01]})

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard Financeiro"
    assert html_response(conn, 200) =~ account.name
    # Monthly summary income/expenses should be present (based on seeds/fixtures logic)
  end

  test "GET / with historical data", %{conn: conn} do
    account = account_fixture()
    # Past month balance
    balance_fixture(%{account_id: account.id, year: 2026, month: 3, final_balance: "400.00"})
    # Create another month to test missing historical summary fallback
    balance_fixture(%{account_id: account.id, year: 2026, month: 2, final_balance: "400.00"})

    import CashLens.CategoriesFixtures
    category_fixed = category_fixture(%{type: "fixed", name: "Fixed Cat"})
    category_var = category_fixture(%{type: "variable", name: "Var Cat"})
    transaction_fixture(%{account_id: account.id, amount: "-100.00", date: ~D[2026-03-01], category_id: category_fixed.id})
    transaction_fixture(%{account_id: account.id, amount: "-50.00", date: ~D[2026-03-02], category_id: category_var.id})

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard Financeiro"
  end

  test "GET /.well-known/appspecific/com.chrome.devtools.json", %{conn: conn} do
    conn = get(conn, "/.well-known/appspecific/com.chrome.devtools.json")
    assert response(conn, 204) == ""
  end
end
