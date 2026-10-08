defmodule CashLensWeb.RecurringItemLiveTest do
  use CashLensWeb.ConnCase

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.ForecastFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Forecast

  defp fixed_category(name), do: category_fixture(%{type: "fixed", name: name})

  defp history_date(months_back, day) do
    today = Date.utc_today()
    month = today.month - months_back
    {year, month} = if month <= 0, do: {today.year - 1, month + 12}, else: {today.year, month}
    Date.new!(year, month, min(day, Date.days_in_month(Date.new!(year, month, 1))))
  end

  describe "listing" do
    test "shows each account with its category, day, amount and origin", %{conn: conn} do
      category = fixed_category("Luz")

      item =
        recurring_item_fixture(%{
          category_id: category.id,
          label: "Luz",
          day_of_month: 14,
          amount: "-334.16"
        })

      {:ok, live, html} = live(conn, ~p"/recurring_items")

      assert has_element?(live, "#recurring-item-#{item.id}")
      assert html =~ "Luz"
      assert html =~ "334,16"
      assert html =~ "detectada"
    end

    test "an item edited by hand is marked, because the sync leaves it alone", %{conn: conn} do
      category = fixed_category("Luz")

      recurring_item_fixture(%{
        category_id: category.id,
        label: "Luz",
        manually_edited: true
      })

      assert live(conn, ~p"/recurring_items") |> elem(2) =~ "manual"
    end

    test "the monthly total counts the active expenses only", %{conn: conn} do
      recurring_item_fixture(%{
        category_id: fixed_category("Luz").id,
        label: "Luz",
        amount: "-100.00"
      })

      recurring_item_fixture(%{
        category_id: fixed_category("Água").id,
        label: "Água",
        amount: "-50.00",
        active: false
      })

      recurring_item_fixture(%{
        category_id: fixed_category("Salário").id,
        label: "Salário",
        amount: "5000.00"
      })

      {:ok, live, _html} = live(conn, ~p"/recurring_items")

      # The whole amount, not a substring of it: a total that also counted the
      # 5.000 salary renders "5.100,00", which contains "100,00".
      assert live |> element("#monthly-total") |> render() =~ "R$ 100,00"
    end

    test "says so when there is nothing registered", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/recurring_items")

      assert has_element?(live, "#empty-state")
    end
  end

  describe "creating" do
    test "registers an account on a free category", %{conn: conn} do
      category = fixed_category("Internet")

      {:ok, live, _html} = live(conn, ~p"/recurring_items/new")

      live
      |> form("#recurring-item-form",
        recurring_item: %{
          category_id: category.id,
          label: "Internet + Celular",
          day_of_month: "10",
          amount: "-241.99"
        }
      )
      |> render_submit()

      assert [item] = Forecast.list_recurring_items()
      assert item.label == "Internet + Celular"
      assert item.day_of_month == 10
    end

    test "a hand-created account is marked as hand-edited", %{conn: conn} do
      # Otherwise the next sync would overwrite the day and amount just typed.
      category = fixed_category("Internet")

      {:ok, live, _html} = live(conn, ~p"/recurring_items/new")

      live
      |> form("#recurring-item-form",
        recurring_item: %{
          category_id: category.id,
          label: "Internet",
          day_of_month: "10",
          amount: "-241.99"
        }
      )
      |> render_submit()

      assert [item] = Forecast.list_recurring_items()
      assert item.manually_edited
    end

    test "a category that already has an account is not offered", %{conn: conn} do
      # One per category is what lets the sync find an item by its category.
      taken = fixed_category("Luz")
      free = fixed_category("Internet")
      recurring_item_fixture(%{category_id: taken.id, label: "Luz"})

      {:ok, live, _html} = live(conn, ~p"/recurring_items/new")

      html = render(live)
      assert html =~ ~s(value="#{free.id}")
      refute html =~ ~s(value="#{taken.id}")
    end

    test "says what to do when every category is taken", %{conn: conn} do
      recurring_item_fixture(%{category_id: fixed_category("Luz").id, label: "Luz"})

      {:ok, live, _html} = live(conn, ~p"/recurring_items/new")

      assert has_element?(live, "#no-free-categories")
    end

    test "an invalid account is refused with its errors", %{conn: conn} do
      category = fixed_category("Internet")

      {:ok, live, _html} = live(conn, ~p"/recurring_items/new")

      html =
        live
        |> form("#recurring-item-form",
          recurring_item: %{category_id: category.id, label: "", day_of_month: "99", amount: "0"}
        )
        |> render_submit()

      assert Forecast.list_recurring_items() == []
      assert html =~ "não pode ser zero"
    end
  end

  describe "editing" do
    setup do
      category = fixed_category("Luz")
      item = recurring_item_fixture(%{category_id: category.id, label: "Luz", day_of_month: 14})
      %{category: category, item: item}
    end

    test "changes the day and amount", %{conn: conn, item: item} do
      {:ok, live, _html} = live(conn, ~p"/recurring_items/#{item.id}/edit")

      live
      |> form("#recurring-item-form",
        recurring_item: %{label: "Luz", day_of_month: "20", amount: "-400.00"}
      )
      |> render_submit()

      reloaded = Forecast.get_recurring_item!(item.id)
      assert reloaded.day_of_month == 20
      assert Decimal.equal?(reloaded.amount, "-400.00")
    end

    test "editing marks it as hand-edited, so the sync stops rewriting it", %{
      conn: conn,
      item: item
    } do
      {:ok, live, _html} = live(conn, ~p"/recurring_items/#{item.id}/edit")

      live
      |> form("#recurring-item-form",
        recurring_item: %{label: "Luz", day_of_month: "20", amount: "-400.00"}
      )
      |> render_submit()

      assert Forecast.get_recurring_item!(item.id).manually_edited
    end

    test "the category cannot be moved once chosen", %{conn: conn, item: item} do
      # The sync finds an item by its category; moving it would orphan both.
      {:ok, live, _html} = live(conn, ~p"/recurring_items/#{item.id}/edit")

      refute has_element?(live, "#recurring-item-form select[name='recurring_item[category_id]']")
    end
  end

  describe "switching off and deleting" do
    setup do
      category = fixed_category("Streaming")
      item = recurring_item_fixture(%{category_id: category.id, label: "Streaming"})
      %{category: category, item: item}
    end

    test "switching off takes it out of the projection and keeps the row", %{
      conn: conn,
      item: item
    } do
      {:ok, live, _html} = live(conn, ~p"/recurring_items")

      live |> element("#toggle-#{item.id}") |> render_click()

      refute Forecast.get_recurring_item!(item.id).active
      assert has_element?(live, "#recurring-item-#{item.id}")
    end

    test "switching on again is one click", %{conn: conn} do
      outra = fixed_category("Jornal")
      item = recurring_item_fixture(%{category_id: outra.id, label: "Off", active: false})
      {:ok, live, _html} = live(conn, ~p"/recurring_items")

      live |> element("#toggle-#{item.id}") |> render_click()

      assert Forecast.get_recurring_item!(item.id).active
    end

    test "deleting frees the category again", %{conn: conn, item: item, category: category} do
      {:ok, live, _html} = live(conn, ~p"/recurring_items")

      live |> element("#delete-#{item.id}") |> render_click()

      assert Forecast.list_recurring_items() == []
      assert category.id in Enum.map(Forecast.list_categories_without_recurring_item(), & &1.id)
    end

    test "deleting asks first, because switching off is the reversible one", %{
      conn: conn,
      item: item
    } do
      {:ok, live, _html} = live(conn, ~p"/recurring_items")

      assert live |> element("#delete-#{item.id}") |> render() =~ "data-confirm"
    end
  end

  describe "resyncing one account" do
    test "re-derives it from history", %{conn: conn} do
      category = fixed_category("Luz")
      account = account_fixture()

      for n <- 0..2 do
        transaction_fixture(%{
          account_id: account.id,
          category_id: category.id,
          date: history_date(n, 14),
          amount: "-334.16"
        })
      end

      item =
        recurring_item_fixture(%{
          category_id: category.id,
          label: "Luz",
          day_of_month: 1,
          manually_edited: true
        })

      {:ok, live, _html} = live(conn, ~p"/recurring_items")

      live |> element("#resync-#{item.id}") |> render_click()

      reloaded = Forecast.get_recurring_item!(item.id)
      assert reloaded.day_of_month == 14
      refute reloaded.manually_edited
    end

    test "says why it cannot, instead of failing silently", %{conn: conn} do
      item = recurring_item_fixture(%{category_id: fixed_category("Luz").id, label: "Luz"})

      {:ok, live, _html} = live(conn, ~p"/recurring_items")

      assert live |> element("#resync-#{item.id}") |> render_click() =~
               "histórico insuficiente"
    end
  end

  test "a background sync rebuilds this screen, which is all about what it changed", %{
    conn: conn
  } do
    {:ok, live, html} = live(conn, ~p"/recurring_items")
    refute html =~ "Luz"

    recurring_item_fixture(%{category_id: fixed_category("Luz").id, label: "Luz"})
    CashLensWeb.RecurringSyncFlash.broadcast(%{created: 1, updated: 0, deactivated: 0})

    assert render(live) =~ "Luz"
  end
end
