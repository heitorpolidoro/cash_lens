defmodule CashLensWeb.TransactionLive.CategorySuggestionTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  alias CashLens.Transactions

  test "uncategorized row shows suggestion pill and clicking applies it", %{conn: conn} do
    category = category_fixture(name: "Padaria")
    transaction_fixture(description: "PADARIA SAO JOSE", category_id: category.id)
    target = transaction_fixture(description: "Padaria São José", amount: "10.0")

    {:ok, live, html} = live(conn, ~p"/transactions")

    assert html =~ "Sugestão: Padaria"

    live
    |> element("button[data-role='category-suggestion'][phx-value-transaction_id='#{target.id}']")
    |> render_click()

    assert Transactions.get_transaction!(target.id).category_id == category.id
    refute has_element?(live, "button[data-role='category-suggestion']")
  end

  test "rows without history show no pill", %{conn: conn} do
    transaction_fixture(description: "SEM HISTORICO ALGUM")

    {:ok, live, _html} = live(conn, ~p"/transactions")

    refute has_element?(live, "button[data-role='category-suggestion']")
  end

  test "pill survives a notes edit on an uncategorized row", %{conn: conn} do
    category = category_fixture(name: "Padaria")
    transaction_fixture(description: "PADARIA SAO JOSE", category_id: category.id)
    target = transaction_fixture(description: "Padaria São José", amount: "10.0")

    {:ok, live, _html} = live(conn, ~p"/transactions")

    assert has_element?(
             live,
             "button[data-role='category-suggestion'][phx-value-transaction_id='#{target.id}']"
           )

    render_click(live, "save_notes", %{"tx_id" => target.id, "notes" => "obs"})

    assert has_element?(
             live,
             "button[data-role='category-suggestion'][phx-value-transaction_id='#{target.id}']"
           )
  end
end
