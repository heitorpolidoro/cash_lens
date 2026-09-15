defmodule CashLensWeb.MonthLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountingFixtures
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

  describe "single month view" do
    test "renders the month detail", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/months/2026/3")
      assert html =~ "Mercado"
      assert has_element?(live, "#single-month-form option[value='3'][selected]")
      assert has_element?(live, "#single-year-form option[value='2026'][selected]")
    end

    test "invalid month redirects to current month", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/months/2026/13")
      assert to =~ "/months/"
    end

    test "non-numeric params redirect to current month", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/months/abc/xyz")
      assert to =~ "/months/"
    end

    test "renders the four KPI cards with a surplus badge", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/months/2026/3")

      assert html =~ "Saldo de Abertura"
      assert html =~ "Receitas"
      assert html =~ "Despesas"
      assert html =~ "Saldo Final"
      # Income 500 - expenses 120 = 380 surplus.
      assert html =~ "Superávit"
      assert html =~ "+R$ 380,00"
      refute html =~ "Déficit"
    end

    test "shows a deficit badge when expenses exceed income", %{conn: conn, acc: acc} do
      transaction_fixture(%{
        account_id: acc.id,
        amount: "-900.00",
        date: ~D[2026-03-20],
        description: "Compra cara"
      })

      {:ok, _live, html} = live(conn, ~p"/months/2026/3")

      assert html =~ "Déficit"
      assert html =~ "-R$ 520,00"
      refute html =~ "Superávit"
    end

    test "opening and final balances sum the month's non-credit-card balances", %{conn: conn} do
      bank = account_fixture()
      card = account_fixture(%{is_credit_card: true})

      balance_fixture(%{
        account_id: bank.id,
        year: 2026,
        month: 3,
        initial_balance: "1000.00",
        final_balance: "1380.00"
      })

      balance_fixture(%{
        account_id: card.id,
        year: 2026,
        month: 3,
        initial_balance: "7777.00",
        final_balance: "8888.00"
      })

      {:ok, _live, html} = live(conn, ~p"/months/2026/3")

      # 1.000,00 from `bank` plus the 120,50 opening the setup account's own March
      # balance carries; its closing 500,50 joins `bank`'s 1.380,00 at the end.
      assert html =~ "R$ 1.120,50"
      assert html =~ "R$ 1.880,50"
      refute html =~ "R$ 7.777,00"
      refute html =~ "R$ 8.888,00"
    end

    test "renders the percentage and progress bar of each category", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/months/2026/3")

      assert html =~ "% do total"
      assert html =~ "100.0%"
      assert html =~ "width: 100"
    end

    test "category percentages are taken against a total that includes credit-card spending", %{
      conn: conn,
      expense_cat: expense_cat
    } do
      card = account_fixture(%{is_credit_card: true})
      bank = account_fixture()
      transport = category_fixture(%{name: "Transporte", slug: "transporte", type: "variable"})

      transaction_fixture(%{
        account_id: card.id,
        category_id: expense_cat.id,
        amount: "-1000.00",
        date: ~D[2026-03-11],
        description: "Mercado no cartao"
      })

      transaction_fixture(%{
        account_id: bank.id,
        category_id: transport.id,
        amount: "-880.00",
        date: ~D[2026-03-13],
        description: "Transporte no debito"
      })

      {:ok, _live, html} = live(conn, ~p"/months/2026/3")

      # Mercado = 120,00 (bank, from setup) + 1.000,00 (card) = 1.120,00 and
      # Transporte = 880,00, so the month's expenses total 2.000,00: the KPI card
      # must equal the sum of the rows, and each row's share must be taken
      # against that same total (56% / 44%), never against a bank-only total.
      assert html =~ "R$ 2.000,00"
      assert html =~ "56.0%"
      assert html =~ "44.0%"
      refute html =~ "112.0%"
      refute html =~ "88.0%"
    end

    test "income percentages are taken against a total that includes credit-card entries", %{
      conn: conn
    } do
      card = account_fixture(%{is_credit_card: true})
      refund_cat = category_fixture(%{name: "Estorno", slug: "estorno", type: "variable"})

      transaction_fixture(%{
        account_id: card.id,
        category_id: refund_cat.id,
        amount: "100.00",
        date: ~D[2026-03-14],
        description: "Estorno no cartao"
      })

      {:ok, _live, html} = live(conn, ~p"/months/2026/3")

      # Renda = 500,00 (bank, from setup) plus Estorno = 100,00 (card) totals
      # 600,00: 83,3% and 16,7%, not 100% / 20% off a bank-only 500,00.
      assert html =~ "R$ 600,00"
      assert html =~ "83.3%"
      assert html =~ "16.7%"
      refute html =~ "20.0%"
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

      transaction_fixture(%{
        account_id: acc.id,
        category_id: shared_cat.id,
        amount: "1000.00",
        date: ~D[2026-03-15],
        description: "Pix recebido"
      })

      transaction_fixture(%{
        account_id: acc.id,
        category_id: shared_cat.id,
        amount: "-150.00",
        date: ~D[2026-03-16],
        description: "Compra loja"
      })

      {:ok, _live, html} = live(conn, ~p"/months/2026/3")

      assert html =~ "R$ 1.000,00"
      assert html =~ "R$ 150,00"
      assert html =~ "receita"
    end

    test "toggle_category expands and collapses an expense row", %{conn: conn, expense_cat: cat} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3")

      selector = "tr[phx-value-category_id='debit:#{cat.id}']"

      html = live |> element(selector) |> render_click()
      assert html =~ "Compra mercado"

      html = live |> element(selector) |> render_click()
      refute html =~ "Compra mercado"
    end

    test "toggle_category expands an income row", %{conn: conn, income_cat: cat} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3")

      html = live |> element("tr[phx-value-category_id='credit:#{cat.id}']") |> render_click()
      assert html =~ "Salário"
    end
  end

  describe "year and month navigation" do
    test "the year arrows move a whole year at a time", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3")

      live |> element("#single-next-year") |> render_click()
      assert_patch(live, ~p"/months/2027/3")

      live |> element("#single-prev-year") |> render_click()
      assert_patch(live, ~p"/months/2026/3")
    end

    test "the month arrows move one month at a time", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3")

      live |> element("#single-next-month") |> render_click()
      assert_patch(live, ~p"/months/2026/4")

      live |> element("#single-prev-month") |> render_click()
      assert_patch(live, ~p"/months/2026/3")
    end

    test "December wraps to January of the next year and January back to December", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/12")
      live |> element("#single-next-month") |> render_click()
      assert_patch(live, ~p"/months/2027/1")

      {:ok, live, _html} = live(conn, ~p"/months/2026/1")
      live |> element("#single-prev-month") |> render_click()
      assert_patch(live, ~p"/months/2025/12")
    end

    test "the year select jumps straight to the chosen year", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3")

      live |> form("#single-year-form", %{"year" => "2024"}) |> render_change()
      assert_patch(live, ~p"/months/2024/3")
    end

    test "the month select jumps straight to the chosen month", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3")

      live |> form("#single-month-form", %{"month" => "9"}) |> render_change()
      assert_patch(live, ~p"/months/2026/9")
    end
  end

  describe "comparison mode" do
    test "the compare button opens the comparison defaulted to the previous month", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/months/2026/3")
      refute html =~ "Mês Base (Referência)"

      html = live |> element("#toggle-compare") |> render_click()

      assert html =~ "Mês Base (Referência)"
      assert html =~ "Mês em Análise (Foco)"
      assert has_element?(live, "#base-month-form option[value='2'][selected]")
      assert_patch(live, ~p"/months/2026/3?compare_year=2026&compare_month=2")
    end

    test "closing the comparison clears the query params", %{conn: conn} do
      {:ok, live, html} =
        live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      assert html =~ "Mês Base (Referência)"

      html = live |> element("#toggle-compare") |> render_click()

      refute html =~ "Mês Base (Referência)"
      assert_patch(live, ~p"/months/2026/3")
    end

    test "renders the base month on the left and the analysed month on the right", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=1")

      assert has_element?(live, "#base-month-form option[value='1'][selected]")
      assert has_element?(live, "#analysis-month-form option[value='3'][selected]")

      {base_pos, _} = :binary.match(html, "Mês Base (Referência)")
      {analysis_pos, _} = :binary.match(html, "Mês em Análise (Foco)")
      assert base_pos < analysis_pos

      assert html =~ "Diferença"
    end

    test "the comparison shows net results instead of account balances", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      assert html =~ "Resultado Líquido"
      assert html =~ "Total Receitas"
      assert html =~ "Total Gastos"
      refute html =~ "Saldo de Abertura"
      refute html =~ "Saldo Final"
      refute html =~ "Superávit"
      refute html =~ "Déficit"
    end

    test "the net result delta compares the analysed month against the base month", %{
      conn: conn,
      acc: acc,
      income_cat: income_cat
    } do
      transaction_fixture(%{
        account_id: acc.id,
        category_id: income_cat.id,
        amount: "100.00",
        date: ~D[2026-02-12],
        description: "Renda fevereiro"
      })

      {:ok, _live, html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      # Base net = +100,00; analysis net = 500 - 120 = +380,00; delta = +280,00.
      assert html =~ "+R$ 100,00"
      assert html =~ "+R$ 380,00"
      assert html =~ "+R$ 280,00"
    end

    test "an invalid compare param is ignored rather than erroring the page", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/months/2026/3?compare_year=abc&compare_month=xyz")
      assert html =~ "Março"
      refute html =~ "Mês Base (Referência)"
    end

    test "a base month that is not before the analysed month falls back to the previous month",
         %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=5")

      assert html =~ "Mês Base (Referência)"
      assert has_element?(live, "#base-month-form option[value='2'][selected]")
      refute has_element?(live, "#base-month-form option[value='5'][selected]")

      # And the corrected pair is what the controls act on from there.
      live |> element("#base-prev-month") |> render_click()
      assert_patch(live, ~p"/months/2026/3?compare_year=2026&compare_month=1")
    end

    test "the base month cannot be moved onto or past the analysed month", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      assert has_element?(live, "#base-next-month[disabled]")
      assert has_element?(live, "#base-next-year[disabled]")

      # And the event itself is refused, not only hidden behind a disabled button.
      render_click(live, "nav", %{"scope" => "base", "unit" => "month", "dir" => "1"})
      assert has_element?(live, "#base-month-form option[value='2'][selected]")
    end

    test "the analysed month cannot be moved onto or before the base month", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      assert has_element?(live, "#analysis-prev-month[disabled]")
      assert has_element?(live, "#analysis-prev-year[disabled]")

      render_click(live, "nav", %{"scope" => "analysis", "unit" => "month", "dir" => "-1"})
      assert has_element?(live, "#analysis-month-form option[value='3'][selected]")
    end

    test "both sides still navigate away from each other", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      live |> element("#base-prev-month") |> render_click()
      assert_patch(live, ~p"/months/2026/3?compare_year=2026&compare_month=1")

      live |> element("#analysis-next-month") |> render_click()
      assert_patch(live, ~p"/months/2026/4?compare_year=2026&compare_month=1")
    end

    test "the base select cannot pick a month at or after the analysed month", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      live |> form("#base-month-form", %{"month" => "1"}) |> render_change()
      assert_patch(live, ~p"/months/2026/3?compare_year=2026&compare_month=1")

      live |> form("#base-month-form", %{"month" => "6"}) |> render_change()
      assert has_element?(live, "#base-month-form option[value='1'][selected]")
    end

    test "comparing the same month of different years is allowed", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/months/2026/3?compare_year=2025&compare_month=3")

      assert html =~ "Mês Base (Referência)"
      assert has_element?(live, "#base-year-form option[value='2025'][selected]")
      assert has_element?(live, "#analysis-year-form option[value='2026'][selected]")
    end
  end

  describe "comparison mode category union" do
    test "a category active only in the base month shows R$ 0,00 and a delta on the analysed side",
         %{conn: conn, acc: acc} do
      only_base = category_fixture(%{name: "SoBase", slug: "so-base", type: "variable"})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: only_base.id,
        amount: "-40.00",
        date: ~D[2026-02-05],
        description: "Só em fevereiro"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      base_row = live |> element("#base-expense-row-#{only_base.id}") |> render()
      assert base_row =~ "SoBase"
      assert base_row =~ "R$ 40,00"

      analysis_row = live |> element("#analysis-expense-row-#{only_base.id}") |> render()
      assert analysis_row =~ "SoBase"
      assert analysis_row =~ "R$ 0,00"
      assert analysis_row =~ "-R$ 40,00"
    end

    test "a category active only in the analysed month shows R$ 0,00 on the base side", %{
      conn: conn,
      expense_cat: expense_cat
    } do
      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      base_row = live |> element("#base-expense-row-#{expense_cat.id}") |> render()
      assert base_row =~ "Mercado"
      assert base_row =~ "R$ 0,00"

      analysis_row = live |> element("#analysis-expense-row-#{expense_cat.id}") |> render()
      assert analysis_row =~ "R$ 120,00"
      assert analysis_row =~ "+R$ 120,00"
    end

    test "comparison percentages use a total that includes credit-card spending", %{
      conn: conn,
      expense_cat: expense_cat
    } do
      card = account_fixture(%{is_credit_card: true})
      bank = account_fixture()
      transport = category_fixture(%{name: "Transporte", slug: "transporte", type: "variable"})

      transaction_fixture(%{
        account_id: card.id,
        category_id: expense_cat.id,
        amount: "-1000.00",
        date: ~D[2026-03-11],
        description: "Mercado no cartao"
      })

      transaction_fixture(%{
        account_id: bank.id,
        category_id: transport.id,
        amount: "-880.00",
        date: ~D[2026-03-13],
        description: "Transporte no debito"
      })

      {:ok, live, html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      # Same arrangement as the single-month regression, seen from the analysed
      # side of a comparison: 1.120,00 of 2.000,00 is 56%, not 112% of a
      # bank-only 1.000,00.
      analysis_row = live |> element("#analysis-expense-row-#{expense_cat.id}") |> render()
      assert analysis_row =~ "R$ 1.120,00"
      assert analysis_row =~ "56.0%"
      refute analysis_row =~ "112.0%"

      transport_row = live |> element("#analysis-expense-row-#{transport.id}") |> render()
      assert transport_row =~ "44.0%"

      # The panel's own "Total Gastos" line agrees with the rows above it.
      assert html =~ "R$ 2.000,00"
    end

    test "a category with no movement in either month is not listed at all", %{
      conn: conn,
      acc: acc
    } do
      dormant = category_fixture(%{name: "Dormente", slug: "dormente", type: "variable"})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: dormant.id,
        amount: "-33.00",
        date: ~D[2026-01-05],
        description: "Só em janeiro"
      })

      {:ok, live, html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      refute html =~ "Dormente"
      refute has_element?(live, "#base-expense-row-#{dormant.id}")
      refute has_element?(live, "#analysis-expense-row-#{dormant.id}")
    end

    test "income categories follow the same union rule", %{
      conn: conn,
      acc: acc,
      income_cat: income_cat
    } do
      only_base_income = category_fixture(%{name: "RendaExtra", slug: "renda-extra"})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: only_base_income.id,
        amount: "60.00",
        date: ~D[2026-02-08],
        description: "Renda extra fevereiro"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      analysis_row = live |> element("#analysis-income-row-#{only_base_income.id}") |> render()
      assert analysis_row =~ "R$ 0,00"
      assert analysis_row =~ "-R$ 60,00"

      base_row = live |> element("#base-income-row-#{income_cat.id}") |> render()
      assert base_row =~ "R$ 0,00"
    end

    test "both panels list exactly the same categories in the same order", %{
      conn: conn,
      acc: acc
    } do
      cat_a = category_fixture(%{name: "CatA", slug: "cat-a", type: "variable"})
      cat_b = category_fixture(%{name: "CatB", slug: "cat-b", type: "variable"})

      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_a.id,
        amount: "-300.00",
        date: ~D[2026-03-05],
        description: "Análise CatA"
      })

      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_b.id,
        amount: "-100.00",
        date: ~D[2026-03-06],
        description: "Análise CatB"
      })

      transaction_fixture(%{
        account_id: acc.id,
        category_id: cat_b.id,
        amount: "-900.00",
        date: ~D[2026-02-06],
        description: "Base CatB"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      base_ids = rendered_row_ids(live, "base-expense-row-")
      analysis_ids = rendered_row_ids(live, "analysis-expense-row-")

      assert base_ids == analysis_ids
      assert cat_a.id in base_ids
      assert cat_b.id in base_ids

      # The analysed month's own ranking drives the shared order (CatA > CatB in March),
      # even though the base month ranks CatB first.
      assert Enum.find_index(base_ids, &(&1 == cat_a.id)) <
               Enum.find_index(base_ids, &(&1 == cat_b.id))
    end

    test "an uncategorized row participates in the union", %{conn: conn, acc: acc} do
      transaction_fixture(%{
        account_id: acc.id,
        amount: "-15.00",
        date: ~D[2026-03-07],
        description: "Sem categoria em março"
      })

      {:ok, live, _html} = live(conn, ~p"/months/2026/3?compare_year=2026&compare_month=2")

      analysis_row = live |> element("#analysis-expense-row-nil") |> render()
      assert analysis_row =~ "R$ 15,00"

      base_row = live |> element("#base-expense-row-nil") |> render()
      assert base_row =~ "R$ 0,00"
    end

    test "a month pair with no movement at all renders the empty states", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/months/2024/7?compare_year=2024&compare_month=6")

      assert html =~ "Nenhuma receita registrada neste mês."
      assert html =~ "Nenhuma despesa registrada neste mês."
    end
  end

  defp rendered_row_ids(live, prefix) do
    live
    |> render()
    |> then(&Regex.scan(~r/id="#{prefix}([^"]+)"/, &1))
    |> Enum.map(fn [_, id] -> id end)
  end
end
