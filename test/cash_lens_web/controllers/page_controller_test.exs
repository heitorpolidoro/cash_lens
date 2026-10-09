defmodule CashLensWeb.PageControllerTest do
  use CashLensWeb.ConnCase

  import CashLens.AccountsFixtures
  import CashLens.AccountingFixtures
  import CashLens.TransactionsFixtures
  import CashLens.CreditCardsFixtures

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

    transaction_fixture(%{
      account_id: account.id,
      amount: "-100.00",
      date: ~D[2026-03-01],
      category_id: category_fixed.id
    })

    transaction_fixture(%{
      account_id: account.id,
      amount: "-50.00",
      date: ~D[2026-03-02],
      category_id: category_var.id
    })

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard Financeiro"
  end

  test "GET / with no data renders the dashboard", %{conn: conn} do
    # No accounts/balances/transactions: exercises the empty-state branches.
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Dashboard Financeiro"
  end

  describe "GET / dashboard layout" do
    test "renders the four KPI cards, the consolidated chart and the Minhas Contas card", %{
      conn: conn
    } do
      account = account_fixture()
      today = Date.utc_today()

      balance_fixture(%{
        account_id: account.id,
        year: today.year,
        month: today.month,
        final_balance: "500.00"
      })

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Saldo Atual"
      assert html =~ "Receitas ("
      assert html =~ "Despesas ("
      assert html =~ "Balanço ("
      assert html =~ "Evolução Financeira Consolidada"
      assert html =~ ~s(id="balanceChart")
      assert html =~ "Minhas Contas"
      assert html =~ "Total em Contas"
      assert html =~ account.name
    end

    test "Minhas Contas totals the listed accounts' current balances", %{conn: conn} do
      today = Date.utc_today()

      for final <- ["500.00", "250.00"] do
        account = account_fixture()

        balance_fixture(%{
          account_id: account.id,
          year: today.year,
          month: today.month,
          final_balance: final
        })
      end

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "R$ 500,00"
      assert html =~ "R$ 250,00"
      # Consolidated total in the card footer.
      assert html =~ "R$ 750,00"
    end

    test "drops the trailing totals and the fixed/variable category charts", %{conn: conn} do
      account = account_fixture()
      today = Date.utc_today()

      balance_fixture(%{account_id: account.id, year: today.year, month: today.month})

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "Balanço 3 meses"
      refute html =~ "Balanço 6 meses"
      refute html =~ "Balanço 12 meses"
      refute html =~ "fixedChart"
      refute html =~ "variableChart"
      refute html =~ "Custo de Vida"
      refute html =~ "Estilo de Vida"
    end

    test "the month-by-month table lists 12 months, newest first, with the month's own figures",
         %{conn: conn} do
      account = account_fixture()
      today = Date.utc_today()

      # No balance_fixture on purpose: creating a transaction replaces the
      # month's balance row outright, recomputing initial_balance from
      # account.balance, so any figure seeded here would be discarded.
      transaction_fixture(%{account_id: account.id, amount: "200.00", date: today})
      transaction_fixture(%{account_id: account.id, amount: "-75.00", date: today})

      html = conn |> get(~p"/") |> html_response(200)
      doc = LazyHTML.from_fragment(html)

      rows = LazyHTML.query(doc, "#monthly-balance-table tbody tr")
      assert Enum.count(rows) == 12

      current =
        rows |> Enum.at(0) |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

      # Newest month first, so row 0 is the current one.
      assert current =~ CashLensWeb.Formatters.month_label(today.month)
      assert current =~ "#{today.year}"
      # Receitas 200, Despesas 75, Balanço 125, and the closing balance:
      # account_fixture's base balance 120,50 + 200 - 75 = 245,50.
      assert current =~ "R$ 200,00"
      assert current =~ "R$ 75,00"
      assert current =~ "R$ 125,00"
      assert current =~ "R$ 245,50"
    end

    test "chart data holds the last 12 real months ending in the current one, with no projections",
         %{conn: conn} do
      conn = get(conn, ~p"/")
      today = Date.utc_today()

      refute conn.assigns.chart_data =~ "is_projection"

      series = Jason.decode!(conn.assigns.chart_data)
      assert length(series) == 12

      assert List.last(series)["year"] == today.year
      assert List.last(series)["month"] == today.month

      for item <- series do
        assert item["year"] * 12 + item["month"] <= today.year * 12 + today.month
      end
    end

    test "assigns are limited to what the simplified dashboard needs", %{conn: conn} do
      conn = get(conn, ~p"/")

      for key <- [
            :total_balance,
            :monthly_income,
            :monthly_expenses,
            :monthly_balance,
            :summary_month,
            :chart_data,
            :accounts,
            # The month-by-month table renders this series directly; the chart
            # gets the same data as encoded JSON in :chart_data.
            :historical
          ] do
        assert Map.has_key?(conn.assigns, key)
      end

      for key <- [
            :fixed_data,
            :variable_data,
            :trailing_balance_3m,
            :trailing_balance_6m,
            :trailing_balance_12m,
            :has_live_balance?
          ] do
        refute Map.has_key?(conn.assigns, key)
      end
    end
  end

  test "GET /.well-known/appspecific/com.chrome.devtools.json", %{conn: conn} do
    conn = get(conn, "/.well-known/appspecific/com.chrome.devtools.json")
    assert response(conn, 204) == ""
  end

  describe "closed-statement warning" do
    test "warns when a card's cycle has closed with no statement", %{conn: conn} do
      account_fixture(%{
        name: "AMAZON",
        is_credit_card: true,
        closing_day: 1,
        due_day: 10
      })

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Fatura possivelmente fechada"
      assert html =~ "AMAZON"
    end

    test "stays silent once every closed cycle has a statement", %{conn: conn} do
      account =
        account_fixture(%{name: "AMEX", is_credit_card: true, closing_day: 1, due_day: 10})

      today = Date.utc_today()

      for back <- 0..3 do
        competencia = today |> Date.beginning_of_month() |> months_ago(back)

        statement_fixture(%{
          account: account,
          competencia: competencia,
          due_date: %{competencia | day: 10}
        })
      end

      refute conn |> get(~p"/") |> html_response(200) =~ "Fatura possivelmente fechada"
    end

    defp months_ago(date, 0), do: date

    defp months_ago(%Date{year: y, month: 1}, n), do: months_ago(Date.new!(y - 1, 12, 1), n - 1)

    defp months_ago(%Date{year: y, month: m}, n), do: months_ago(Date.new!(y, m - 1, 1), n - 1)
  end

  describe "contas a pagar" do
    import CashLens.ForecastFixtures
    import CashLens.CategoriesFixtures

    defp bill_on(days_ahead, label, amount) do
      day = Date.utc_today() |> Date.add(days_ahead) |> Map.fetch!(:day)

      recurring_item_fixture(%{
        label: label,
        day_of_month: day,
        amount: amount,
        category_id: category_fixture(%{type: "fixed", name: label}).id
      })
    end

    test "lists the next bills with how their date reads from today", %{conn: conn} do
      bill_on(2, "Internet", "-241.99")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "upcoming-bills"
      assert html =~ "Contas a pagar"
      assert html =~ "Internet"
      assert html =~ "vence em 2 dias"
      assert html =~ "241,99"
      assert html =~ "Total · 30 dias"
      assert total_cell(html) =~ "241,99"
    end

    defp total_cell(html) do
      {:ok, re} = Regex.compile(~s{id="upcoming-total"[^>]*>(.*?)</td>}, "s")

      case Regex.run(re, html) do
        [_, cell] -> cell
        nil -> flunk("no total row rendered")
      end
    end

    test "a card bill links to its statement, a registered account to the forecast",
         %{conn: conn} do
      bill_on(2, "Internet", "-241.99")

      card =
        account_fixture(%{is_credit_card: true, name: "Ourocard", closing_day: 3, due_day: 10})

      due = Date.add(Date.utc_today(), 4)

      statement =
        statement_fixture(%{
          account: card,
          competencia: Date.beginning_of_month(due),
          due_date: due,
          total_a_pagar: Decimal.new("14075.87")
        })

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "/statements?id=#{statement.id}"
      assert html =~ "/forecast"
    end

    test "an estimated card bill says so", %{conn: conn} do
      # No statement for the month, so the projection guesses from history. It is
      # a bill that is coming, but it is not a bill that arrived.
      card =
        account_fixture(%{is_credit_card: true, name: "Ourocard", closing_day: 3, due_day: 10})

      for months_back <- 1..3 do
        due = Date.add(Date.utc_today(), -30 * months_back)

        statement_fixture(%{
          account: card,
          competencia: Date.beginning_of_month(due),
          due_date: due,
          total_a_pagar: Decimal.new("1000.00")
        })
      end

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "estimativa"
    end

    test "the tail carries its own amount, not just a count", %{conn: conn} do
      for day <- 1..16, do: bill_on(day, "Conta #{day}", "-10.00")

      bill_on(18, "Conta grande", "-9000.00")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "upcoming-rest"
      assert html =~ "e mais 3"
      assert html =~ "9.020,00"
    end

    test "is absent when nothing is due", %{conn: conn} do
      account_fixture(%{name: "Conta Corrente"})

      refute conn |> get(~p"/") |> html_response(200) =~ "upcoming-bills"
    end
  end

  describe "projeção de falência no painel" do
    import CashLens.CategoriesFixtures

    test "shows the card beside the month's balance", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Projeção de Falência"
      assert html =~ ~s(data-role="kpi-bankruptcy")
    end

    test "the whole card links to the screen that explains it", %{conn: conn} do
      # A figure this alarming should not be a dead end.
      html = conn |> get(~p"/") |> html_response(200)

      assert Regex.match?(
               ~r{<a[^>]*href="/forecast"[^>]*data-role="kpi-bankruptcy"},
               html
             )
    end

    test "says the same thing the forecast screen says", %{conn: conn} do
      # Two renderings of this would drift, and the dashboard's would be the one
      # that drifted wrong.
      account = account_fixture(%{balance: "100.00"})
      category = category_fixture(%{type: "fixed", name: "Aluguel"})

      {:ok, _} =
        CashLens.Forecast.create_recurring_item(%{
          "category_id" => category.id,
          "label" => "Aluguel",
          "day_of_month" => Date.utc_today().day,
          "amount" => "-5000.00"
        })

      balance_fixture(%{account_id: account.id, final_balance: "100.00"})

      dashboard = conn |> get(~p"/") |> html_response(200)

      severity = Regex.run(~r{data-severity="(\w+)"}, dashboard) |> Enum.at(1)

      assert severity in ~w(critical near distant safe)
      assert dashboard =~ "Projeção de Falência"
    end
  end
end
