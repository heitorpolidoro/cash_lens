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

    test "a category present in both months is ordered by the primary panel, even when the compare panel's own ranking differs",
         %{conn: conn, acc: acc} do
      cat_a = category_fixture(%{name: "CatA", slug: "cat-a", type: "variable"})
      cat_b = category_fixture(%{name: "CatB", slug: "cat-b", type: "variable"})

      # Primary (March): CatA is the bigger expense.
      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_a.id,
        amount: "-300.00",
        date: ~D[2026-03-05],
        description: "Primary CatA"
      })

      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_b.id,
        amount: "-100.00",
        date: ~D[2026-03-06],
        description: "Primary CatB"
      })

      # Compare (February): CatB is the bigger expense — the opposite ranking.
      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_a.id,
        amount: "-50.00",
        date: ~D[2026-02-05],
        description: "Compare CatA"
      })

      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_b.id,
        amount: "-200.00",
        date: ~D[2026-02-06],
        description: "Compare CatB"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      primary_html = live |> element("#primary") |> render()
      compare_html = live |> element("#compare") |> render()

      {a_pos_primary, _} = :binary.match(primary_html, "CatA")
      {b_pos_primary, _} = :binary.match(primary_html, "CatB")
      {a_pos_compare, _} = :binary.match(compare_html, "CatA")
      {b_pos_compare, _} = :binary.match(compare_html, "CatB")

      # Primary's own order (CatA bigger, so first) governs both panels — even
      # though the compare panel's own unaligned ranking would put CatB first.
      assert a_pos_primary < b_pos_primary
      assert a_pos_compare < b_pos_compare
    end

    test "a category present only on the primary side shows a real value there and a R$ 0,00 placeholder, non-clickable, on the compare side",
         %{conn: conn, acc: acc} do
      only_primary = category_fixture(%{name: "SoPrimario", slug: "so-primario", type: "fixed"})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: only_primary.id,
        amount: "-77.00",
        date: ~D[2026-03-05],
        description: "Only on primary"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      row_key = "debit:#{only_primary.id}"

      # Real, clickable row on the primary side.
      assert has_element?(
               live,
               "#primary tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      primary_row = live |> element("#primary tr[phx-value-category_id='#{row_key}']") |> render()
      assert primary_row =~ "R$ 77,00"

      # Placeholder, non-clickable row on the compare side, still showing the name.
      refute has_element?(
               live,
               "#compare tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      assert has_element?(live, "#compare tr[phx-value-category_id='#{row_key}']")
      compare_row = live |> element("#compare tr[phx-value-category_id='#{row_key}']") |> render()
      assert compare_row =~ "SoPrimario"
      assert compare_row =~ "R$ 0,00"
    end

    test "a category present only on the compare side appears after the primary's own categories, with a placeholder on the primary side",
         %{conn: conn, acc: acc, expense_cat: primary_cat} do
      only_compare =
        category_fixture(%{name: "SoComparado", slug: "so-comparado", type: "variable"})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: only_compare.id,
        amount: "-40.00",
        date: ~D[2026-02-05],
        description: "Only on compare"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      # setup/0 already gave `acc` a "Mercado" (primary_cat) expense in March.
      primary_html = live |> element("#primary") |> render()
      {primary_cat_pos, _} = :binary.match(primary_html, primary_cat.name)
      {only_compare_pos, _} = :binary.match(primary_html, "SoComparado")
      assert primary_cat_pos < only_compare_pos

      row_key = "debit:#{only_compare.id}"

      refute has_element?(
               live,
               "#primary tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      primary_row = live |> element("#primary tr[phx-value-category_id='#{row_key}']") |> render()
      assert primary_row =~ "SoComparado"
      assert primary_row =~ "R$ 0,00"

      assert has_element?(
               live,
               "#compare tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      compare_row = live |> element("#compare tr[phx-value-category_id='#{row_key}']") |> render()
      assert compare_row =~ "R$ 40,00"
    end

    test "an uncategorized (sem categoria) row participates in the same alignment", %{
      conn: conn,
      acc: acc
    } do
      transaction_fixture(%{
        account_id: acc.id,
        amount: "-15.00",
        date: ~D[2026-03-07],
        description: "Sem categoria em março"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      row_key = "debit:nil"

      primary_row = live |> element("#primary tr[phx-value-category_id='#{row_key}']") |> render()
      assert primary_row =~ "R$ 15,00"

      refute has_element?(
               live,
               "#compare tr[phx-value-category_id='#{row_key}'][phx-click='toggle_category']"
             )

      compare_row = live |> element("#compare tr[phx-value-category_id='#{row_key}']") |> render()
      assert compare_row =~ "R$ 0,00"
    end

    test "income and expense sections align independently of each other", %{
      conn: conn,
      acc: acc,
      income_cat: primary_income_cat
    } do
      only_compare_income =
        category_fixture(%{name: "RendaSoComparado", slug: "renda-so-comparado"})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: only_compare_income.id,
        amount: "60.00",
        date: ~D[2026-02-08],
        description: "Renda só em fevereiro"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare=2026-2")

      # setup/0 gave `acc` a "Renda" (primary_income_cat) income in March — the primary
      # panel's own income category still appears (real value), unaffected by the fact
      # that the *expense* alignment (tested elsewhere) is a completely separate list.
      primary_html = live |> element("#primary") |> render()
      assert primary_html =~ primary_income_cat.name

      row_key = "credit:#{only_compare_income.id}"
      primary_row = live |> element("#primary tr[phx-value-category_id='#{row_key}']") |> render()
      assert primary_row =~ "R$ 0,00"
    end

    test "outside comparison mode, a single panel never renders placeholder rows", %{
      conn: conn,
      expense_cat: cat
    } do
      {:ok, live, html} = live(conn, ~p"/months/2026/3")
      refute has_element?(live, "tr.opacity-40")
      assert html =~ cat.name
    end
  end
end
