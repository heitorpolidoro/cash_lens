defmodule CashLensWeb.BalanceLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountingFixtures
  import CashLens.AccountsFixtures

  @update_attrs %{
    initial_balance: "456.7",
    final_balance: "456.7",
    income: "456.7",
    expenses: "456.7",
    balance: "456.7"
  }
  @invalid_attrs %{initial_balance: nil}

  defp create_balance(_) do
    balance = balance_fixture()
    %{balance: balance}
  end

  describe "Index" do
    setup [:create_balance]

    test "lists all balances", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/balances")
      assert html =~ "Listando Balanços"
    end

    test "saves new balance", %{conn: conn} do
      account = account_fixture()
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert {:ok, form_live, _} =
               index_live
               |> element("a", "Novo Balanço")
               |> render_click()
               |> follow_redirect(conn, ~p"/balances/new")

      assert render(form_live) =~ "Gerar Balanços Mensais"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#balance-form", %{month: 1, year: 2026, account_ids: [account.id]})
               |> render_submit()
               |> follow_redirect(conn, ~p"/balances")

      html = render(index_live)
      assert html =~ "Balanços gerados!"
    end

    test "updates balance in listing", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#balances-#{balance.id} a[href$='/edit']")
               |> render_click()
               |> follow_redirect(conn, ~p"/balances/#{balance}/edit")

      assert render(form_live) =~ "Editar Balanço"

      assert form_live
             |> form("#balance-form", balance: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#balance-form", balance: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/balances")

      html = render(index_live)
      assert html =~ "Balanço atualizado!"
    end

    test "deletes balance in listing", %{conn: conn, balance: balance} do
      {:ok, index_live, _html} = live(conn, ~p"/balances")

      assert index_live
             |> element("#balances-#{balance.id} button[phx-click='confirm_delete']")
             |> render_click()

      assert index_live |> element("button", "Sim, Apagar") |> render_click()
      refute has_element?(index_live, "#balances-#{balance.id}")
    end
  end

  describe "Show" do
    setup [:create_balance]

    test "displays balance", %{conn: conn, balance: balance} do
      {:ok, _show_live, html} = live(conn, ~p"/balances/#{balance}")
      assert html =~ "Balanço"
    end

    test "updates balance and returns to list", %{conn: conn, balance: balance} do
      {:ok, show_live, _html} = live(conn, ~p"/balances/#{balance}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a[href$='/edit?return_to=show']")
               |> render_click()
               |> follow_redirect(conn, ~p"/balances/#{balance}/edit?return_to=show")

      assert render(form_live) =~ "Editar Balanço"

      assert form_live
             |> form("#balance-form", balance: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_live, _html} =
               form_live
               |> form("#balance-form", balance: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/balances")

      html = render(index_live)
      assert html =~ "Balanço atualizado!"
    end
  end
end
