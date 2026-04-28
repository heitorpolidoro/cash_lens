defmodule CashLensWeb.AutomationLive.BulkIgnoreTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias CashLens.Transactions

  test "renders, creates, and deletes patterns", %{conn: conn} do
    unique_id = System.unique_integer([:positive])
    pattern_str = "^PIX_#{unique_id}"

    {:ok, _pattern} =
      Transactions.create_bulk_ignore_pattern(%{pattern: pattern_str, description: "Ignore PIX"})

    {:ok, live, _html} = live(conn, ~p"/admin/exclusion_rules")

    assert render(live) =~ pattern_str

    new_pattern = "^DOC_#{unique_id}"

    html =
      live
      |> form("#ignore-form", %{"bulk_ignore_pattern" => %{"pattern" => new_pattern}})
      |> render_submit()

    assert html =~ "Padrão cadastrado"
    assert render(live) =~ new_pattern

    pattern = hd(Transactions.list_bulk_ignore_patterns())

    html =
      live
      |> element("button[phx-click='delete'][phx-value-id='#{pattern.id}']")
      |> render_click()

    assert html =~ "Padrão removido"
  end
end
