defmodule CashLensWeb.MonthLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  setup do
    acc = account_fixture()
    expense_cat = category_fixture(%{name: "Mercado", slug: "mercado"})
    income_cat = category_fixture(%{name: "Renda", slug: "renda"})

    transaction_fixture(%{
      account_id: acc.id,
      category_id: expense_cat.id,
      amount: "-120.00",
      date: ~D[2026-03-10],
      description: "Compra mercado"
    })

    transaction_fixture(%{
      account_id: acc.id,
      category_id: income_cat.id,
      amount: "500.00",
      date: ~D[2026-03-12],
      description: "Salário"
    })

    %{acc: acc, expense_cat: expense_cat, income_cat: income_cat}
  end

  test "renders the month detail", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/months/2026/3")
    assert html =~ "Março"
    assert html =~ "Mercado"
  end

  test "invalid month redirects to current month", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/months/2026/13")
    assert to =~ "/months/"
  end

  test "non-numeric params redirect to current month", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/months/abc/xyz")
    assert to =~ "/months/"
  end

  test "toggle_category expands and collapses a row", %{conn: conn, expense_cat: cat} do
    {:ok, live, _html} = live(conn, ~p"/months/2026/3")

    row_key = "debit:#{cat.id}"

    html = render_click(live, "toggle_category", %{"category_id" => row_key})
    assert html =~ "Compra mercado"

    # Toggling again collapses it.
    render_click(live, "toggle_category", %{"category_id" => row_key})
    refute has_element?(live, "[data-row-key='#{row_key}'] .expanded")
  end

  test "toggle_category expands an income row", %{conn: conn, income_cat: cat} do
    {:ok, live, _html} = live(conn, ~p"/months/2026/3")

    html = render_click(live, "toggle_category", %{"category_id" => "credit:#{cat.id}"})
    assert html =~ "Salário"
  end

  test "January links to the previous year and December to the next", %{conn: conn} do
    {:ok, _live, jan} = live(conn, ~p"/months/2026/1")
    assert jan =~ "/months/2025/12"

    {:ok, _live, dec} = live(conn, ~p"/months/2026/12")
    assert dec =~ "/months/2027/1"
  end

  test "renders empty-state messages for a month with no data", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/months/2024/7")
    assert html =~ "Nenhuma despesa registrada neste mês."
    assert html =~ "Nenhuma receita registrada neste mês."
  end

  test "separates income and expenses of the same category without subtracting", %{conn: conn} do
    acc = account_fixture()

    shared_cat =
      category_fixture(%{name: "Compartilhado", slug: "compartilhado", type: "variable"})

    # Positive transaction (credit) in Shared category
    transaction_fixture(%{
      account_id: acc.id,
      category_id: shared_cat.id,
      amount: "1000.00",
      date: ~D[2026-03-15],
      description: "Pix recebido"
    })

    # Negative transaction (debit) in Shared category
    transaction_fixture(%{
      account_id: acc.id,
      category_id: shared_cat.id,
      amount: "-150.00",
      date: ~D[2026-03-16],
      description: "Compra loja"
    })

    {:ok, _live, html} = live(conn, ~p"/months/2026/3")

    # Compartilhado should show 1000.00 in the Receitas table
    assert html =~ "R$ 1.000,00"
    # Compartilhado should show 150.00 in the Gastos table
    assert html =~ "R$ 150,00"
    # The sub-label "receita" should be rendered
    assert html =~ "receita"
  end
end
