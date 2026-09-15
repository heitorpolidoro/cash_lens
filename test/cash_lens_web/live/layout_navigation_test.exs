defmodule CashLensWeb.LayoutNavigationTest do
  @moduledoc """
  The global layout is the frame every screen renders inside, so these tests
  exercise it through real routes rather than in isolation.
  """
  use CashLensWeb.ConnCase

  import Phoenix.LiveViewTest

  alias CashLensWeb.Layouts

  test "the dashboard renders the consolidated sidebar and the global topbar", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    for group <- Layouts.nav_groups(), item <- group.items do
      assert html =~ ~s(href="#{item.path}"), "missing sidebar entry for #{item.label}"
    end

    assert html =~ "Importar Extratos"
    assert html =~ "Nova Transação"
    assert html =~ ~s(id="sidebar-toggle")
  end

  test "a LiveView gets its current path assigned, highlighting its sidebar entry", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/balances")

    assert html =~ ~r{<a[^>]+href="/balances"[^>]*class="[^"]*bg-blue-50[^"]*text-blue-600}
    assert html =~ "Saldos Cont"
  end

  test "every mapped screen renders inside the layout without crashing", %{conn: conn} do
    # `/transfers` queries `category_id == ^transfer_cat_id`, which raises when
    # no "transfer" category exists (a pre-existing issue in the Transactions
    # context, unrelated to the layout). Seed it so the screen can render.
    CashLens.CategoriesFixtures.category_fixture(%{name: "Transfer"})

    live_paths =
      for group <- Layouts.nav_groups(),
          item <- group.items,
          item.path != "/",
          do: item.path

    for path <- live_paths do
      assert {:ok, _view, html} = live(conn, path), "#{path} failed to render"
      assert html =~ ~s(id="sidebar-toggle"), "#{path} rendered without the global layout"
    end
  end
end
