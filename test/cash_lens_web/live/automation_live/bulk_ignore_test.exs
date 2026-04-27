defmodule CashLensWeb.AutomationLive.BulkIgnoreTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias CashLens.Transactions

  test "renders, creates, and deletes patterns", %{conn: conn} do
    {:ok, _pattern} =
      Transactions.create_bulk_ignore_pattern(%{pattern: "^PIX", description: "Ignore PIX"})

    {:ok, live, _html} = live(conn, ~p"/admin/exclusion_rules")

    assert render(live) =~ "^PIX"

    html =
      live
      |> form("#ignore-form", %{"bulk_ignore_pattern" => %{"pattern" => "^DOC"}})
      |> render_submit()

    assert html =~ "Padrão cadastrado"
    assert render(live) =~ "^DOC"

    pattern = hd(Transactions.list_bulk_ignore_patterns())

    html =
      live
      |> element("button[phx-click='delete'][phx-value-id='#{pattern.id}']")
      |> render_click()

    assert html =~ "Padrão removido"
  end
end
