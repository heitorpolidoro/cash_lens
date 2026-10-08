defmodule CashLensWeb.RecurringSyncFlashTest do
  use CashLensWeb.ConnCase

  import Phoenix.LiveViewTest

  alias CashLensWeb.RecurringSyncFlash

  describe "a finished background sync reaches the screen the person is on" do
    test "the forecast hears it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/forecast")

      RecurringSyncFlash.broadcast(%{created: 2, updated: 3, deactivated: 1})

      assert render(view) =~
               "Histórico sincronizado: 2 contas incluídas, 3 contas atualizadas, 1 conta desativada."
    end

    test "so does a screen that has nothing to do with the forecast", %{conn: conn} do
      # The sync fires seconds after an import, by which time the person has
      # usually moved on. On the forecast alone the message would reach nobody.
      {:ok, view, _html} = live(conn, ~p"/transactions")

      RecurringSyncFlash.broadcast(%{created: 1, updated: 0, deactivated: 0})

      assert render(view) =~ "Histórico sincronizado: 1 conta incluída."
    end

    test "only the counts that moved are named", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/forecast")

      RecurringSyncFlash.broadcast(%{created: 0, updated: 4, deactivated: 0})

      html = render(view)
      assert html =~ "Histórico sincronizado: 4 contas atualizadas."
      refute html =~ "incluída"
      refute html =~ "desativada"
    end

    test "a sync that changed nothing says nothing", %{conn: conn} do
      # It runs after every import, and most imports change no recurrence. Said
      # every time, the message would train itself to be ignored.
      {:ok, view, _html} = live(conn, ~p"/forecast")

      RecurringSyncFlash.broadcast(%{created: 0, updated: 0, deactivated: 0})

      refute render(view) =~ "Histórico sincronizado"
    end

    test "the projection on screen is rebuilt, not left disagreeing", %{conn: conn} do
      category = CashLens.CategoriesFixtures.category_fixture(%{type: "fixed", name: "Luz"})

      {:ok, view, html} = live(conn, ~p"/forecast")
      refute html =~ "Luz"

      {:ok, _item} =
        CashLens.Forecast.create_recurring_item(%{
          "category_id" => category.id,
          "label" => "Luz",
          "day_of_month" => 14,
          "amount" => "-334.16"
        })

      RecurringSyncFlash.broadcast(%{created: 1, updated: 0, deactivated: 0})

      assert render(view) =~ "Luz"
    end
  end
end
