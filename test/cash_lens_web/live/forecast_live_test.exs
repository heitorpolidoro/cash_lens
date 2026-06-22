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
      assert html =~ "Não fica negativo"
      assert html =~ "Nenhuma conta fixa detectada"
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
      html = live |> element("button", "Sincronizar com Histórico") |> render_click()

      assert html =~ "Água"
    end

    test "toggle_active flips the item and updates the projection", %{conn: conn} do
      item = recurring_item_fixture(%{active: true})

      {:ok, live, _html} = live(conn, ~p"/forecast")
      live |> element("button[phx-click='toggle_active']") |> render_click()

      assert CashLens.Forecast.get_recurring_item!(item.id).active == false
    end

    test "update_day persists a manual edit", %{conn: conn} do
      item = recurring_item_fixture(%{day_of_month: 5})

      {:ok, live, _html} = live(conn, ~p"/forecast")

      live
      |> element("input[phx-value-id='#{item.id}'][phx-blur='update_day']")
      |> render_blur(%{"value" => "20"})

      reloaded = CashLens.Forecast.get_recurring_item!(item.id)
      assert reloaded.day_of_month == 20
      assert reloaded.manually_edited == true
    end

    test "change_target_date recalculates the projected balance", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/forecast")

      html =
        live
        |> element("form[phx-change='change_target_date']")
        |> render_change(%{"date" => Date.add(Date.utc_today(), 5) |> Date.to_iso8601()})

      assert html =~ "Saldo em"
    end
  end
end
