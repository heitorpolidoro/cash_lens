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
    selector = "tr[phx-value-category_id='#{row_key}']"

    html = live |> element(selector) |> render_click()
    assert html =~ "Compra mercado"

    # Toggling again collapses it.
    live |> element(selector) |> render_click()
    refute has_element?(live, "[data-row-key='#{row_key}'] .expanded")
  end

  test "toggle_category expands an income row", %{conn: conn, income_cat: cat} do
    {:ok, live, _html} = live(conn, ~p"/months/2026/3")

    row_key = "credit:#{cat.id}"
    html = live |> element("tr[phx-value-category_id='#{row_key}']") |> render_click()
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

  describe "comparison mode" do
    test "Comparar button opens a second panel defaulted to the previous month", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/months/2026/3")
      refute html =~ "Fechar comparação"

      html = live |> element("button", "Comparar") |> render_click()

      assert html =~ "Fechar comparação"
      assert html =~ "Fevereiro"
      assert_patch(live, ~p"/months/2026/3?compare=2026-2")
    end

    test "Fechar comparação closes the second panel and clears the URL param", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/months/2026/3?compare=2026-2")
      assert html =~ "Fechar comparação"

      html = live |> element("button", "Fechar comparação") |> render_click()

      refute html =~ "Fechar comparação"
      assert_patch(live, ~p"/months/2026/3")
    end

    test "loading a URL with ?compare= directly renders both panels", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/months/2026/3?compare=2026-1")
      assert html =~ "Março"
      assert html =~ "Janeiro"
    end

    test "the primary panel's arrows preserve the compare param", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-1")

      live |> element("#primary a[href*='/months/2026/4']") |> render_click()

      assert_patch(live, ~p"/months/2026/4?compare=2026-1")
    end

    test "the compare panel's arrows only change the compare param", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-1")

      live |> element("#compare a[href*='compare=2026-2']") |> render_click()

      assert_patch(live, ~p"/months/2026/3?compare=2026-2")
    end

    test "expanding a category in one panel does not expand it in the other", %{
      conn: conn,
      acc: acc,
      expense_cat: cat
    } do
      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat.id,
        amount: "-40.00",
        date: ~D[2026-02-05],
        description: "Compra fevereiro"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      row_key = "debit:#{cat.id}"
      live |> element("#compare tr[phx-value-category_id='#{row_key}']") |> render_click()

      compare_html = live |> element("#compare") |> render()
      primary_html = live |> element("#primary") |> render()

      assert compare_html =~ "Compra fevereiro"
      refute primary_html =~ "Compra fevereiro"
    end

    test "an invalid compare param is ignored rather than erroring the page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/months/2026/3?compare=garbage")
      assert html =~ "Março"
      refute html =~ "Fechar comparação"
    end

    test "December wraps to January of the next year for both panels", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/12?compare=2026-12")

      assert live |> element("#primary a[href*='/months/2027/1']") |> has_element?()
      assert live |> element("#compare a[href*='compare=2027-1']") |> has_element?()
    end

    test "primary and compare set to the same month render without crashing", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-3")

      primary_html = live |> element("#primary") |> render()
      compare_html = live |> element("#compare") |> render()

      assert primary_html =~ "Março"
      assert compare_html =~ "Março"
    end
  end
end
