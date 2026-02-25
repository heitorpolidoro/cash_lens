defmodule CashLensWeb.BalanceLiveTest do
  use CashLensWeb.ConnCase

  import Phoenix.LiveViewTest
  import CashLens.AccountingFixtures

  @create_attrs %{balance: "120.5", month: 42, year: 42, initial_balance: "120.5", income: "120.5", expenses: "120.5", final_balance: "120.5"}
  @update_attrs %{balance: "456.7", month: 43, year: 43, initial_balance: "456.7", income: "456.7", expenses: "456.7", final_balance: "456.7"}
  @invalid_attrs %{balance: nil, month: nil, year: nil, initial_balance: nil, income: nil, expenses: nil, final_balance: nil}
  defp create_balance(_) do
    balance = balance_fixture()

    %{balance: balance}
  end

  describe "Index" do
    setup [:create_balance]

    test "lists all balances", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/balances")

      assert html =~ "Listing Balances"
    end

    test "saves new balance", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "New Balance")
               |> render_click()
               |> follow_redirect(conn, ~p"/balances/new")

      assert render(form_live) =~ "New Balance"

      assert form_live
             |> form("#balance-form", balance: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#balance-form", balance: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/balances")

      html = render(index_live)
      assert html =~ "Balance created successfully"
    end

    test "updates balance in listing", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#balances-#{balance.id} a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/balances/#{balance}/edit")

      assert render(form_live) =~ "Edit Balance"

      assert form_live
             |> form("#balance-form", balance: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#balance-form", balance: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/balances")

      html = render(index_live)
      assert html =~ "Balance updated successfully"
    end

    test "deletes balance in listing", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert index_live |> element("#balances-#{balance.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#balances-#{balance.id}")
    end
  end

  describe "Show" do
    setup [:create_balance]

    test "displays balance", %{conn: conn, balance: balance} do
      {:ok, _show_live, html} = live(conn, ~p"/balances/#{balance}")

      assert html =~ "Show Balance"
    end

    test "updates balance and returns to show", %{conn: conn, balance: balance} do
      {:ok, show_live, _html} = live(conn, ~p"/balances/#{balance}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/balances/#{balance}/edit?return_to=show")

      assert render(form_live) =~ "Edit Balance"

      assert form_live
             |> form("#balance-form", balance: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, show_live, _html} =
               form_live
               |> form("#balance-form", balance: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/balances/#{balance}")

      html = render(show_live)
      assert html =~ "Balance updated successfully"
    end
  end
end
