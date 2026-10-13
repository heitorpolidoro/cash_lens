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

  test "GET / sees a category re-parented under transfer between two requests", %{conn: conn} do
    import CashLens.CategoriesFixtures

    transfer = category_fixture(%{name: "Transferência", slug: "transfer", type: "variable"})
    moved = category_fixture(%{name: "Movida", type: "variable"})
    account = account_fixture()

    transaction_fixture(%{
      account_id: account.id,
      amount: "321.00",
      date: Date.utc_today(),
      category_id: moved.id
    })

    first = get(conn, ~p"/")
    assert Decimal.equal?(first.assigns.monthly_income, Decimal.new("321.00"))

    {:ok, _} =
      CashLens.Categories.update_category(CashLens.Ownership.current_user!(), moved, %{
        parent_id: transfer.id
      })

    second = get(conn, ~p"/")
    assert Decimal.equal?(second.assigns.monthly_income, Decimal.new("0"))
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
        closing_day: Date.utc_today() |> Date.add(-1) |> Map.fetch!(:day),
        due_day: 10
      })

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Fatura possivelmente fechada"
      assert html =~ "AMAZON"
    end

    test "waits until the day after closing", %{conn: conn} do
      today = Date.utc_today()
      # Due day on the far side of the closing day keeps the closing-today
      # competência at a known month: this one when due follows closing, else next.
      due_day = if today.day < 28, do: 28, else: 15
      current = Date.beginning_of_month(today)

      closing_today_competencia =
        if due_day > today.day, do: current, else: Date.shift(current, month: 1)

      account =
        account_fixture(%{
          name: "HOJE",
          is_credit_card: true,
          closing_day: today.day,
          due_day: due_day
        })

      # Every older cycle has its statement; only the one closing today is missing.
      for back <- 1..3 do
        competencia = Date.shift(closing_today_competencia, month: -back)

        statement_fixture(%{
          account: account,
          competencia: competencia,
          due_date: %{competencia | day: due_day}
        })
      end

      refute conn |> get(~p"/") |> html_response(200) =~ "Fatura possivelmente fechada"
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

      due = Date.add(Date.utc_today(), 4)

      card =
        account_fixture(%{
          is_credit_card: true,
          name: "Ourocard",
          closing_day: 3,
          due_day: min(due.day, 28)
        })

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

    # The card leads with three lines and keeps the list behind "detalhar". The
    # risk of a <details> is that the summary and the list disagree, or that the
    # list is simply gone, so both are asserted here.
    test "leads with three lines that add up to the same total as the list", %{conn: conn} do
      bill_on(1, "Internet", "-241.99")
      bill_on(4, "Imposto", "-216.59")
      bill_on(20, "Seguro", "-147.69")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(id="upcoming-summary")

      next_row = bill_row(html, "upcoming-next")
      assert next_row =~ "Próximo vencimento"
      assert next_row =~ "1 conta · vence amanhã"
      assert next_row =~ "241,99"
      # The bill's own name belongs to the list, not to the summary line.
      refute next_row =~ "Internet"
      assert bill_row(html, "upcoming-soon") =~ "216,59"
      assert bill_row(html, "upcoming-later") =~ "147,69"
      # 241,99 + 216,59 + 147,69
      assert bill_row(html, "upcoming-summary-total") =~ "606,27"
      assert total_cell(html) =~ "606,27"
    end

    test "the full list is still there, one click behind the summary", %{conn: conn} do
      bill_on(2, "Internet", "-241.99")
      bill_on(5, "Condomínio", "-461.39")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "<details"
      assert html =~ "detalhar"
      assert html =~ "resumir"
      # Every bill, by name, not only the ones the summary happens to name.
      assert bill_row(html, "upcoming-recurring-", :prefix) =~ "Internet"
      assert html =~ "Condomínio"
    end

    # A bill whose day passed with nothing on its category is still owed, and
    # the first line has to stop calling it the *next* thing to pay.
    # The dashboard reads the real clock, and on the 1st no day of the month has
    # passed yet -- the scenario cannot exist. Skipped out loud rather than
    # wrapped in an `if` that would pass having asserted nothing.
    @tag skip: Date.utc_today().day == 1 && "no day has passed yet on the 1st"
    test "an overdue bill leads the card, and says it is late", %{conn: conn} do
      account = account_fixture()

      recurring_item_fixture(%{
        label: "Gás",
        day_of_month: 1,
        amount: "-47.48",
        category_id: category_fixture(%{type: "fixed", name: "Gás"}).id
      })

      # The ledger has to reach the due date, or nothing is claimed.
      transaction_fixture(%{account_id: account.id, date: Date.utc_today(), amount: "-1.00"})

      html = conn |> get(~p"/") |> html_response(200)

      next_row = bill_row(html, "upcoming-next")
      assert next_row =~ "Em atraso"
      assert next_row =~ "venceu"
      assert next_row =~ "47,48"
      refute next_row =~ "Próximo vencimento"
    end

    test "an empty bucket says so instead of showing nothing against zero", %{conn: conn} do
      bill_on(1, "Internet", "-241.99")

      html = conn |> get(~p"/") |> html_response(200)

      assert bill_row(html, "upcoming-soon") =~ "nada"
      assert bill_row(html, "upcoming-later") =~ "nada"
    end

    defp bill_row(html, id, :prefix) do
      {:ok, re} = Regex.compile(~s{id="#{id}[^"]*"(.*?)</tr>}, "s")

      case Regex.run(re, html) do
        [_, row] -> row
        nil -> flunk("no row whose id starts with #{id}")
      end
    end

    defp bill_row(html, id) do
      {:ok, re} = Regex.compile(~s{id="#{id}"[^>]*>(.*?)</tr>}, "s")

      case Regex.run(re, html) do
        [_, row] -> row
        nil -> flunk("no #{id} rendered")
      end
    end

    test "is absent when nothing is due", %{conn: conn} do
      account_fixture(%{name: "Conta Corrente"})

      refute conn |> get(~p"/") |> html_response(200) =~ "upcoming-bills"
    end
  end

  describe "lista de contas no painel" do
    import CashLens.AccountsFixtures

    test "follows the order arranged on the accounts screen", %{conn: conn} do
      alfa = account_fixture(%{name: "Alfa"})
      bravo = account_fixture(%{name: "Bravo"})

      :ok =
        CashLens.Accounts.reorder_accounts(CashLens.Ownership.current_user!(), [bravo.id, alfa.id])

      html = conn |> get(~p"/") |> html_response(200)

      assert :binary.match(html, "Bravo") < :binary.match(html, "Alfa")
    end

    test "an investment is tagged, and still counted", %{conn: conn} do
      account_fixture(%{name: "Conta", balance: "100.00"})
      account_fixture(%{name: "Tesouro", balance: "5000.00", is_investment: true})

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "investimento"
      # The flag is a label: 100 + 5000 is still the balance the screen shows.
      assert html =~ "5.100,00"
    end
  end

  describe "histórico mensal abaixo do gráfico" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    defp month_of_spending(months_back) do
      Enum.reduce(0..months_back//1, Date.beginning_of_month(Date.utc_today()), fn _i, acc ->
        acc |> Date.add(-1) |> Date.beginning_of_month()
      end)
    end

    test "shows six months open and keeps the rest behind ver mais", %{conn: conn} do
      account = account_fixture()

      for months_back <- 0..8 do
        transaction_fixture(%{
          account_id: account.id,
          date: month_of_spending(months_back),
          amount: "-100.00"
        })
      end

      html = conn |> get(~p"/") |> html_response(200)

      rows = history_rows(html)
      # Twelve months are always rendered -- the series is a fixed window --
      # and exactly six of them are open.
      assert length(rows) == 12
      assert Enum.count(rows, &(&1 =~ "hidden expanded:table-row")) == 6

      assert html =~ ~s(id="monthly-balance-toggle")
      assert html =~ "ver mais 6 meses"
      assert html =~ "ver menos"
    end

    # The rows the toggle reveals must already be in the document: a "ver mais"
    # that needs a request is a different feature, and a slower one.
    test "the hidden months are rendered, not fetched", %{conn: conn} do
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        date: month_of_spending(8),
        amount: "-4321.00"
      })

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "4.321,00"
    end

    defp history_rows(html) do
      {:ok, re} = Regex.compile(~s{<tr([^>]*)>(?:(?!</tr>).)*?/months/}, "s")

      re |> Regex.scan(html) |> Enum.map(fn [_, attrs] -> attrs end)
    end
  end

  describe "ritmo de gasto no card de despesas" do
    import CashLens.AccountsFixtures
    import CashLens.TransactionsFixtures

    test "the expenses card says the daily rate and how it compares", %{conn: conn} do
      account = account_fixture()
      today = Date.utc_today()
      month = Date.beginning_of_month(today)
      previous = month |> Date.add(-1) |> Date.beginning_of_month()

      transaction_fixture(%{account_id: account.id, date: previous, amount: "-300.00"})
      transaction_fixture(%{account_id: account.id, date: month, amount: "-100.00"})

      html = conn |> get(~p"/") |> html_response(200)

      rate = cell(html, "spend-rate")
      assert rate =~ "/dia"
      assert rate =~ "vs. média de 1 mês"
      # An arrow, either way -- the direction is the point of the comparison.
      assert rate =~ "▲" or rate =~ "▼"
    end

    test "with no earlier month there is a rate but nothing to compare it to", %{conn: conn} do
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        date: Date.beginning_of_month(Date.utc_today()),
        amount: "-100.00"
      })

      rate = conn |> get(~p"/") |> html_response(200) |> cell("spend-rate")

      assert rate =~ "/dia"
      refute rate =~ "vs. média"
      refute rate =~ "▲"
      refute rate =~ "▼"
    end

    defp cell(html, id) do
      {:ok, re} = Regex.compile(~s{id="#{id}"[^>]*>(.*?)</div>}, "s")

      case Regex.run(re, html) do
        [_, block] -> block
        nil -> flunk("no #{id} rendered")
      end
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
