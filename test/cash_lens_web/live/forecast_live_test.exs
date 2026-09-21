defmodule CashLensWeb.ForecastLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.ForecastFixtures
  import CashLens.TransactionsFixtures
  import CashLensWeb.Formatters

  alias CashLens.Forecast

  # Counts how many times a marker appears in the rendered HTML. Simpler and more
  # readable here than parsing the document for a handful of data-role markers.
  defp count(html, marker), do: html |> String.split(marker) |> length() |> Kernel.-(1)

  defp scoped(view, selector), do: view |> element(selector) |> render()

  describe "KPI cards" do
    test "renders the pre-salary balance, the 30-day minimum and the 12-month projection", %{
      conn: conn
    } do
      account_fixture(%{balance: "10000.00"})
      today = Date.utc_today()
      recurring_item_fixture(%{day_of_month: today.day, amount: "-500.00", label: "Aluguel"})

      recurring_item_fixture(%{
        day_of_month: today.day,
        amount: "4000.00",
        label: "Salário",
        is_salary: true
      })

      projection = Forecast.project()
      income_date = Forecast.next_income_date(projection)
      pre_salary = Forecast.balance_on(projection, Date.add(income_date, -1))
      minimum = Forecast.minimum_point(projection, 30)

      {:ok, view, html} = live(conn, ~p"/forecast")

      assert html =~ "Saldo Pré-Salário"
      assert scoped(view, "[data-role='kpi-pre-salary']") =~ format_currency(pre_salary)

      assert html =~ "Mínimo Projetado (30d)"
      assert scoped(view, "[data-role='kpi-minimum']") =~ format_currency(minimum.balance_after)
      assert scoped(view, "[data-role='kpi-minimum']") =~ "Seguro"

      assert html =~ "Projeção em 12 Meses"

      assert scoped(view, "[data-role='kpi-twelve-months']") =~
               format_currency(Forecast.final_balance(Forecast.project(365)))
    end

    test "the minimum badge reads Em risco when the projected minimum is negative", %{conn: conn} do
      account_fixture(%{balance: "100.00"})
      today = Date.utc_today()
      recurring_item_fixture(%{day_of_month: today.day, amount: "-5000.00"})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      kpi = scoped(view, "[data-role='kpi-minimum']")
      assert kpi =~ "Em risco"
      refute kpi =~ "Seguro"
    end

    test "the 12-month card carries the signed percentage change against the current balance", %{
      conn: conn
    } do
      account_fixture(%{balance: "10000.00"})
      recurring_item_fixture(%{day_of_month: Date.utc_today().day, amount: "-100.00"})

      percent = Forecast.projected_change_percent(Forecast.project(365))
      assert Decimal.negative?(percent)

      {:ok, view, _html} = live(conn, ~p"/forecast")

      assert scoped(view, "[data-role='kpi-twelve-months']") =~ "#{Decimal.to_string(percent)}%"
    end

    test "the KPI row has exactly three cards and no record count anywhere", %{conn: conn} do
      account_fixture(%{balance: "10000.00"})
      recurring_item_fixture(%{})

      {:ok, _view, html} = live(conn, ~p"/forecast")

      assert count(html, "data-role=\"kpi-") == 3
      assert html =~ "md:grid-cols-3"
      refute html =~ "Recorrências Ativas"
      refute html =~ "configuradas"
    end
  end

  describe "liquidity ruler" do
    test "is headed with the 90-day window and renders every occurrence of that window", %{
      conn: conn
    } do
      account_fixture(%{balance: "10000.00"})
      recurring_item_fixture(%{day_of_month: Date.utc_today().day, amount: "-500.00"})

      projection = Forecast.project()
      expected = Forecast.occurrences_within(projection, 90)

      {:ok, view, html} = live(conn, ~p"/forecast")

      assert html =~ "Régua Temporal de Liquidez (Próximos 90 Dias)"
      assert count(html, "data-role=\"ruler-event\"") == length(expected)

      ruler = scoped(view, "[data-role='ruler']")

      for occ <- expected do
        assert ruler =~ format_currency(occ.balance_after)
      end
    end

    test "scrolls horizontally inside its own card, in a single non-wrapping row", %{conn: conn} do
      account_fixture(%{balance: "10000.00"})
      recurring_item_fixture(%{day_of_month: Date.utc_today().day, amount: "-500.00"})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      strip = scoped(view, "[data-role='ruler-strip']")
      assert strip =~ "flex-nowrap"
      assert strip =~ "overflow-x-auto"
      refute strip =~ "scrollbar-hide"
    end

    test "renders the balance more prominently than the event's own amount", %{conn: conn} do
      account_fixture(%{balance: "10000.00"})
      recurring_item_fixture(%{day_of_month: Date.utc_today().day, amount: "-500.00"})

      {:ok, _view, html} = live(conn, ~p"/forecast")

      assert html =~ "data-role=\"ruler-balance\""
      assert html =~ "text-lg font-black"
      assert html =~ "data-role=\"ruler-amount\""
    end

    test "the 30-day KPI ignores a lower balance that only happens after day 30", %{conn: conn} do
      account_fixture(%{balance: "10000.00"})
      recurring_item_fixture(%{day_of_month: Date.utc_today().day, amount: "-500.00"})

      projection = Forecast.project()
      min_30 = Forecast.minimum_point(projection, 30)
      min_90 = Forecast.minimum_point(projection, 90)

      assert Decimal.compare(min_30.balance_after, min_90.balance_after) == :gt

      {:ok, view, _html} = live(conn, ~p"/forecast")

      kpi = scoped(view, "[data-role='kpi-minimum']")
      assert kpi =~ "30d"
      assert kpi =~ format_currency(min_30.balance_after)
      refute kpi =~ format_currency(min_90.balance_after)

      # ...while the later, lower occurrence is on the ruler.
      assert scoped(view, "[data-role='ruler']") =~ format_currency(min_90.balance_after)
    end

    test "renders a credit-card bill as a ruler event marked Fatura de cartão", %{conn: conn} do
      account_fixture(%{balance: "10000.00"})

      card =
        account_fixture(%{is_credit_card: true, closing_day: 3, due_day: 10, name: "Ourocard"})

      due_date = Forecast.next_occurrence_date(10, Date.utc_today())

      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: due_date,
        competencia: Date.beginning_of_month(due_date),
        total_a_pagar: Decimal.new("500.00")
      })

      projection = Forecast.project()

      bill =
        Enum.find(projection.occurrences, &(Map.get(&1, :origin) == :boleto))

      {:ok, view, html} = live(conn, ~p"/forecast")

      assert html =~ "Fatura Ourocard"
      assert html =~ "Fatura de cartão"
      assert scoped(view, "[data-role='ruler']") =~ format_currency(bill.balance_after)
    end
  end

  describe "installment disclosure on the card bill" do
    setup do
      account_fixture(%{balance: "10000.00"})

      card =
        account_fixture(%{is_credit_card: true, closing_day: 3, due_day: 10, name: "Nubank"})

      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: Date.add(Date.utc_today(), -30),
        competencia: Date.beginning_of_month(Date.add(Date.utc_today(), -30)),
        total_a_pagar: Decimal.new("2000.00")
      })

      %{card: card}
    end

    test "states how much of the estimated bill is installments and lists the groups", %{
      conn: conn,
      card: card
    } do
      month = Date.beginning_of_month(Date.add(Date.utc_today(), 60))

      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "NOTEBOOK DELL",
          installments: 10,
          start_date: month,
          total_amount: Decimal.new("6200.00")
        })

      transaction_fixture(%{
        account_id: card.id,
        installment_group_id: group.id,
        installment_number: 1,
        date: month,
        amount: Decimal.new("-620.00")
      })

      total = CashLens.Installments.account_installment_total(card.id, month)

      {:ok, _view, html} = live(conn, ~p"/forecast")

      assert html =~ "dos quais #{format_currency(total)} são parcelas"
      assert html =~ "NOTEBOOK DELL"
      assert html =~ "Parcela 1/10"
    end

    test "omits the disclosure when nothing is billed in the month", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/forecast")

      assert html =~ "Fatura de cartão"
      refute html =~ "são parcelas"
    end
  end

  describe "temporary recurrences" do
    test "renders an off-card commitment with its parcel position and end month", %{conn: conn} do
      account_fixture(%{balance: "10000.00"})
      checking = account_fixture(%{balance: "0.00"})

      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "FINANCIAMENTO IMOVEL",
          commitment_type: "financing",
          installments: 3,
          start_date: Date.utc_today(),
          total_amount: Decimal.new("4440.00")
        })

      transaction_fixture(%{
        account_id: checking.id,
        installment_group_id: group.id,
        date: Date.utc_today(),
        amount: Decimal.new("-1480.00"),
        description: "parcela financiamento"
      })

      ends_on = CashLens.Installments.last_installment_date(group)

      {:ok, view, html} = live(conn, ~p"/forecast")

      ruler = scoped(view, "[data-role='ruler']")

      assert ruler =~ "Recorrência temporária"
      assert ruler =~ "FINANCIAMENTO IMOVEL"
      assert ruler =~ "Parcela 1/3"
      assert ruler =~ "termina em #{Calendar.strftime(ends_on, "%m/%Y")}"
      assert ruler =~ "Parcela 3/3"
      assert ruler =~ "Última parcela"
      assert ruler =~ format_currency(Decimal.new("-1480.00"))

      # A commitment is a projection event, never a registered recurring item.
      assert count(html, "data-role=\"recurring-item\"") == 0
      refute scoped(view, "[data-role='items-list']") =~ "FINANCIAMENTO IMOVEL"
    end
  end

  describe "recurring items list" do
    test "renders one row per registered item and no count in the heading", %{conn: conn} do
      account_fixture(%{balance: "10000.00"})
      item = recurring_item_fixture(%{day_of_month: 12, amount: "-77.00"})
      recurring_item_fixture(%{day_of_month: 20, amount: "-33.00", label: "Outro"})

      {:ok, view, html} = live(conn, ~p"/forecast")

      assert count(html, "data-role=\"recurring-item\"") == 2
      assert html =~ item.label
      assert html =~ "77,00"

      heading = scoped(view, "[data-role='items-heading']")
      assert heading =~ "Lançamentos Recorrentes Cadastrados"
      # The heading itself carries no count of any kind.
      [_, heading_text] = Regex.run(~r{<h2[^>]*>(.*)</h2>}s, heading)
      refute heading_text =~ ~r/\d/
    end

    test "toggle_active flips the item and updates the projection", %{conn: conn} do
      item = recurring_item_fixture(%{active: true})

      {:ok, view, _html} = live(conn, ~p"/forecast")
      view |> element("button[phx-click='toggle_active']") |> render_click()

      assert Forecast.get_recurring_item!(item.id).active == false
    end

    test "toggle_salary marks the item as the main salary", %{conn: conn} do
      item = recurring_item_fixture(%{amount: "3000.00"})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      view
      |> element("button[phx-click='toggle_salary'][phx-value-id='#{item.id}']")
      |> render_click()

      assert Forecast.get_recurring_item!(item.id).is_salary

      view
      |> element("button[phx-click='toggle_salary'][phx-value-id='#{item.id}']")
      |> render_click()

      refute Forecast.get_recurring_item!(item.id).is_salary
    end
  end

  describe "ruler date labels" do
    test "marks today and tomorrow", %{conn: conn} do
      account_fixture(%{balance: "10000.00"})
      today = Date.utc_today()
      checking = account_fixture(%{balance: "0.00"})

      {:ok, group} =
        CashLens.Installments.create_installment_group(%{
          description_pattern: "COMPROMISSO AMANHA",
          installments: 2,
          start_date: Date.add(today, 1),
          total_amount: Decimal.new("200.00")
        })

      transaction_fixture(%{
        account_id: checking.id,
        installment_group_id: group.id,
        date: Date.add(today, 1),
        amount: Decimal.new("-100.00"),
        description: "parcela amanha"
      })

      recurring_item_fixture(%{day_of_month: today.day, amount: "-10.00"})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      ruler = scoped(view, "[data-role='ruler']")
      assert ruler =~ "(Hoje)"
      assert ruler =~ "(Amanhã)"
    end
  end

  describe "edit modal" do
    test "opens, saves a manual edit and closes", %{conn: conn} do
      item = recurring_item_fixture(%{day_of_month: 5})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      view
      |> element("button[phx-click='open_edit'][phx-value-id='#{item.id}']")
      |> render_click()

      assert has_element?(view, "form[phx-submit='save_item']")

      view
      |> element("form[phx-submit='save_item']")
      |> render_submit(%{"day_of_month" => "20", "amount" => item.amount})

      reloaded = Forecast.get_recurring_item!(item.id)
      assert reloaded.day_of_month == 20
      assert reloaded.manually_edited == true
      refute has_element?(view, "form[phx-submit='save_item']")
    end

    test "closes without saving", %{conn: conn} do
      item = recurring_item_fixture(%{day_of_month: 5})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      view
      |> element("button[phx-click='open_edit'][phx-value-id='#{item.id}']")
      |> render_click()

      view |> element("button[phx-click='close_modal']") |> render_click()

      refute has_element?(view, "form[phx-submit='save_item']")
      assert Forecast.get_recurring_item!(item.id).day_of_month == 5
    end

    test "keeps the modal open and reports invalid values", %{conn: conn} do
      item = recurring_item_fixture(%{day_of_month: 5})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      view
      |> element("button[phx-click='open_edit'][phx-value-id='#{item.id}']")
      |> render_click()

      html =
        view
        |> element("form[phx-submit='save_item']")
        |> render_submit(%{"day_of_month" => "77", "amount" => "-10.00"})

      assert html =~ "Valores inválidos"
      assert has_element?(view, "form[phx-submit='save_item']")
      assert Forecast.get_recurring_item!(item.id).day_of_month == 5
    end

    test "reports insufficient history when re-syncing an item without transactions", %{
      conn: conn
    } do
      item = recurring_item_fixture(%{})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      view
      |> element("button[phx-click='open_edit'][phx-value-id='#{item.id}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='resync_item'][phx-value-id='#{item.id}']")
        |> render_click()

      assert html =~ "Histórico insuficiente para ressincronizar."
      assert has_element?(view, "form[phx-submit='save_item']")
    end

    test "re-syncs the item with history", %{conn: conn} do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      for {ago, amount} <- [{40, "-52.00"}, {10, "-50.00"}] do
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          date: Date.add(Date.utc_today(), -ago),
          amount: amount
        })
      end

      item =
        recurring_item_fixture(%{
          category_id: category.id,
          day_of_month: 1,
          amount: "-1.00",
          label: "Água"
        })

      {:ok, view, _html} = live(conn, ~p"/forecast")

      view
      |> element("button[phx-click='open_edit'][phx-value-id='#{item.id}']")
      |> render_click()

      view
      |> element("button[phx-click='resync_item'][phx-value-id='#{item.id}']")
      |> render_click()

      reloaded = Forecast.get_recurring_item!(item.id)
      refute reloaded.manually_edited
      assert Decimal.equal?(reloaded.amount, Decimal.new("-50.00"))
    end
  end

  describe "creating a recurring item" do
    test "offers only the categories without an item and excludes credit-card ones", %{conn: conn} do
      free = category_fixture(%{name: "Academia Mensal", type: "fixed"})
      taken = category_fixture(%{name: "Aluguel Fixo", type: "fixed"})
      card = category_fixture(%{name: "Cartao de Credito", type: "fixed"})
      recurring_item_fixture(%{category_id: taken.id, label: "Aluguel Fixo"})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      render_click(view, "open_new", %{})
      select = scoped(view, "select[name='category_id']")

      assert select =~ free.name
      refute select =~ taken.name
      refute select =~ card.name
    end

    test "picking another category re-fills the label with its name", %{conn: conn} do
      first = category_fixture(%{name: "Academia Mensal", type: "fixed"})
      second = category_fixture(%{name: "Seguro Residencial", type: "fixed"})

      {:ok, view, _html} = live(conn, ~p"/forecast")
      render_click(view, "open_new", %{})

      assert scoped(view, "input[name='label']") =~ first.name

      html =
        view
        |> element("form[phx-submit='save_item']")
        |> render_change(%{
          "category_id" => second.id,
          "label" => first.name,
          "day_of_month" => "",
          "amount" => ""
        })

      assert html =~ second.name
      assert scoped(view, "input[name='label']") =~ second.name
    end

    test "creates the item, marks it manually_edited and shows it in the list", %{conn: conn} do
      account_fixture(%{balance: "10000.00"})
      category = category_fixture(%{name: "Seguro Residencial", type: "fixed"})

      {:ok, view, _html} = live(conn, ~p"/forecast")

      render_click(view, "open_new", %{})

      html =
        view
        |> element("form[phx-submit='save_item']")
        |> render_submit(%{
          "category_id" => category.id,
          "label" => "Seguro Residencial",
          "day_of_month" => "9",
          "amount" => "-480.00"
        })

      assert [item] = Forecast.list_recurring_items()
      assert item.category_id == category.id
      assert item.day_of_month == 9
      assert item.manually_edited == true
      assert item.is_salary == false
      assert html =~ "Seguro Residencial"
      refute has_element?(view, "form[phx-submit='save_item']")
    end

    test "the create form does not offer the salary flag", %{conn: conn} do
      category_fixture(%{name: "Seguro Residencial", type: "fixed"})

      {:ok, view, _html} = live(conn, ~p"/forecast")
      render_click(view, "open_new", %{})

      refute has_element?(view, "form[phx-submit='save_item'] input[name='is_salary']")
      refute has_element?(view, "button[phx-click='resync_item']")
    end

    test "a hand-created item survives sync_all/0 unchanged", %{conn: conn} do
      category = category_fixture(%{name: "Internet", type: "fixed"})
      account = account_fixture()

      # History that would suggest a different day and amount.
      for {ago, amount} <- [{20, "-90.00"}, {50, "-95.00"}] do
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          date: Date.add(Date.utc_today(), -ago),
          amount: amount
        })
      end

      {:ok, suggestion} = Forecast.suggest_for_category(category)

      {:ok, view, _html} = live(conn, ~p"/forecast")
      render_click(view, "open_new", %{})

      view
      |> element("form[phx-submit='save_item']")
      |> render_submit(%{
        "category_id" => category.id,
        "label" => "Internet",
        "day_of_month" => "3",
        "amount" => "-42.00"
      })

      assert [created] = Forecast.list_recurring_items()
      refute suggestion["day_of_month"] == created.day_of_month
      refute Decimal.equal?(suggestion["amount"], created.amount)

      assert %{updated: 0} = Forecast.sync_all()

      reloaded = Forecast.get_recurring_item!(created.id)
      assert reloaded.day_of_month == 3
      assert Decimal.equal?(reloaded.amount, Decimal.new("-42.00"))
    end

    test "rejects an out-of-range day and a zero amount, keeping the modal open", %{conn: conn} do
      category = category_fixture(%{name: "Academia", type: "fixed"})

      {:ok, view, _html} = live(conn, ~p"/forecast")
      render_click(view, "open_new", %{})

      html =
        view
        |> element("form[phx-submit='save_item']")
        |> render_submit(%{
          "category_id" => category.id,
          "label" => "Academia",
          "day_of_month" => "40",
          "amount" => "-10.00"
        })

      assert Forecast.list_recurring_items() == []
      assert html =~ "Valores inválidos"
      assert has_element?(view, "form[phx-submit='save_item']")

      view
      |> element("form[phx-submit='save_item']")
      |> render_submit(%{
        "category_id" => category.id,
        "label" => "Academia",
        "day_of_month" => "10",
        "amount" => "0"
      })

      assert Forecast.list_recurring_items() == []
      assert has_element?(view, "form[phx-submit='save_item']")
    end

    test "disables the action when every eligible category already has an item", %{conn: conn} do
      recurring_item_fixture(%{})

      {:ok, view, html} = live(conn, ~p"/forecast")

      assert Forecast.list_categories_without_recurring_item() == []
      assert has_element?(view, "button[phx-click='open_new'][disabled]")
      assert html =~ "Todas as categorias já possuem um lançamento recorrente"

      render_click(view, "open_new", %{})
      refute has_element?(view, "form[phx-submit='save_item']")
    end
  end

  describe "history sync" do
    test "explains what the sync does, unconditionally, on the initial render", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/forecast")

      assert html =~ "Sincronizar Histórico"
      assert html =~ "Sincronização manual — só acontece quando você clica aqui."
      assert html =~ "Fixo (Contas Essenciais)"
      assert html =~ "2 lançamentos nos últimos 180 dias"
      assert html =~ "mediana"
      assert html =~ "lançamento mais recente"
      assert html =~ "Esta sincronização não altera itens editados à mão"
      assert html =~ "marcar a categoria como Fixo é o que a torna elegível"
    end

    test "sync_all creates items from history", %{conn: conn} do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      for ago <- [10, 40] do
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          date: Date.add(Date.utc_today(), -ago),
          amount: "-50.00"
        })
      end

      {:ok, view, _html} = live(conn, ~p"/forecast")
      html = view |> element("button[phx-click='sync_all']") |> render_click()

      assert html =~ "Água"
      assert [_item] = Forecast.list_recurring_items()
    end
  end

  describe "empty state" do
    test "renders the screen with no recurring item at all", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/forecast")

      assert html =~ "Previsão"
      assert html =~ "Nenhum lançamento recorrente cadastrado"
      assert count(html, "data-role=\"ruler-event\"") == 0
    end
  end
end
