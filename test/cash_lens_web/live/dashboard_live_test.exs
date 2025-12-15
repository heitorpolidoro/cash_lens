defmodule CashLensWeb.Live.DashboardLiveTest do
  use CashLensWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ExUnit.Assertions

  alias CashLens.Accounts
  alias CashLens.Transactions
  alias CashLens.Account
  alias CashLens.Transaction
  alias CashLens.Repo
  alias MongoDB.BSON.ObjectId

  @tag :with_live_view
  setup %{conn: conn} do
    :ok = Repo.delete_all(Transaction)
    :ok = Repo.delete_all(Account)

    user_id = ObjectId.generate()
    {:ok, account} = Accounts.create_account(%{name: "Dashboard Account", user_id: user_id})

    # Insert some test data
    Transactions.bulk_insert_transactions([
      %{date: ~D[2025-01-01], description: "Jan Income", amount: Decimal.new("1000.00"), type: "income", account_id: account.id},
      %{date: ~D[2025-01-15], description: "Jan Expense", amount: Decimal.new("-500.00"), type: "expense", account_id: account.id},
      %{date: ~D[2025-02-01], description: "Feb Income", amount: Decimal.new("2000.00"), type: "income", account_id: account.id},
      %{date: ~D[2025-02-10], description: "Feb Expense", amount: Decimal.new("-300.00"), type: "expense", account_id: account.id}
    ])

    %{conn: conn, user_id: user_id}
  end

  test "renders dashboard with chart data when transactions exist", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/dashboard")

    # Assert that the chart container is present
    assert has_element?(lv, "#financial-chart")

    # Assert that no "No data to display" message is shown
    refute has_element?(lv, "p", "No data to display. Upload some statements!")

    # Since the chart is SVG, we can't easily assert on its content directly,
    # but we can check for key elements or attributes that Contex would render.
    # This is a basic check.
    assert has_element?(lv, "svg")
    assert has_element?(lv, "text", "Monthly Financial Overview")
    assert has_element?(lv, "text", "Amount")
    assert has_element?(lv, "text", "Month")
  end

  test "renders dashboard with no data message when no transactions exist", %{conn: conn} do
    # Clear all transactions
    :ok = Repo.delete_all(Transaction)

    {:ok, lv, _html} = live(conn, "/dashboard")

    # Assert that the "No data" message is shown
    assert has_element?(lv, "p", "No data to display. Upload some statements!")
    assert has_element?(lv, "a", "Upload Statement")
    refute has_element?(lv, "#financial-chart") # Ensure chart is not rendered
  end
end
