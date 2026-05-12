defmodule CashLensWeb.BalanceLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountingFixtures
  import CashLens.AccountsFixtures

  defp create_balance(_) do
    balance = balance_fixture()
    %{balance: balance}
  end

  describe "Index" do
    setup [:create_balance]

    test "lists all balances", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/balances")
      assert html =~ "Balance History"
    end

    test "filters balances by year", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      html =
        index_live
        |> form("#filter-form", %{"year" => balance.year, "month" => "", "account_id" => ""})
        |> render_change()

      assert html =~ to_string(balance.year)
    end

    test "clears filters", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      render_click(index_live, "clear_filters", %{})
      assert render(index_live) =~ "Balance History"
    end

    test "recalculates all balances", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      html = render_click(index_live, "recalculate_all", %{})
      assert html =~ "recalculated"
    end

    test "renders balance with account that has no icon (shows initials)", %{conn: conn} do
      account = account_fixture(%{bank: "MyBank", icon: nil})
      balance_fixture(%{account_id: account.id})
      {:ok, _live, html} = live(conn, ~p"/balances")
      assert html =~ "My"
    end

    test "balances are read-only and actions are hidden", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert render(index_live) =~ "Read-only"
      refute has_element?(index_live, "#balances-#{balance.id} a[href$='/edit']")

      refute has_element?(
               index_live,
               "#balances-#{balance.id} button[phx-click='confirm_delete']"
             )
    end
  end
end
