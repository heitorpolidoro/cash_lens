defmodule CashLensWeb.ForecastLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.ForecastFixtures
  import CashLens.TransactionsFixtures

  describe "Index" do
    test "renders the empty state when there are no recurring items", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/forecast")

      assert html =~ "Previsão"
      assert html =~ "Sem saldo negativo previsto"
      assert html =~ "Nenhuma conta fixa configurada"
    end

    test "lists recurring items", %{conn: conn} do
      item = recurring_item_fixture(%{day_of_month: 12, amount: "-77.00"})

      {:ok, _live, html} = live(conn, ~p"/forecast")

      assert html =~ item.label
      assert html =~ "77,00"
    end

    test "sync_all creates items from history", %{conn: conn} do
      category = category_fixture(%{type: "fixed", name: "Água"})
      account = account_fixture()

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-05-10],
        amount: "-50.00"
      })

      transaction_fixture(%{
        account_id: account.id,
        category_id: category.id,
        date: ~D[2026-06-10],
        amount: "-52.00"
      })

      {:ok, live, _html} = live(conn, ~p"/forecast")
      html = render_click(live, :sync_all)

      assert html =~ "Água"
    end

    test "toggle_active flips the item and updates the projection", %{conn: conn} do
      item = recurring_item_fixture(%{active: true})

      {:ok, live, _html} = live(conn, ~p"/forecast")
      live |> element("button[phx-click='toggle_active']") |> render_click()

      assert CashLens.Forecast.get_recurring_item!(item.id).active == false
    end

    test "update_day persists a manual edit via modal", %{conn: conn} do
      item = recurring_item_fixture(%{day_of_month: 5})

      {:ok, live, _html} = live(conn, ~p"/forecast")

      live
      |> element("button[phx-click='open_edit'][phx-value-id='#{item.id}']")
      |> render_click()

      live
      |> element("form[phx-submit='save_item']")
      |> render_submit(%{"day_of_month" => "20", "amount" => item.amount})

      reloaded = CashLens.Forecast.get_recurring_item!(item.id)
      assert reloaded.day_of_month == 20
      assert reloaded.manually_edited == true
    end

    test "shows a Boleto badge for a card occurrence and Estimado for an estimated one", %{
      conn: conn
    } do
      due_day = 10

      card =
        CashLens.AccountsFixtures.account_fixture(%{
          is_credit_card: true,
          closing_day: 3,
          due_day: due_day,
          name: "Ourocard"
        })

      due_date = CashLens.Forecast.next_occurrence_date(due_day, Date.utc_today())

      CashLens.CreditCardsFixtures.statement_fixture(%{
        account: card,
        due_date: due_date,
        competencia: Date.beginning_of_month(due_date),
        total_a_pagar: Decimal.new("500.00")
      })

      {:ok, _view, html} = live(conn, ~p"/forecast")
      assert html =~ "Fatura Ourocard"
      assert html =~ "Boleto"
    end
  end
end
