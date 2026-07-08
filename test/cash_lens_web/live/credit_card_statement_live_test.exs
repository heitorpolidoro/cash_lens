defmodule CashLensWeb.CreditCardStatementLiveTest do
  use CashLensWeb.ConnCase
  import Phoenix.LiveViewTest
  import CashLens.CreditCardsFixtures

  test "overview lists statements", %{conn: conn} do
    account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, name: "Ourocard"})
    statement_fixture(%{account: account})

    {:ok, _view, html} = live(conn, ~p"/statements")
    assert html =~ "Ourocard"
  end

  test "detail view shows statement info and open payment band", %{conn: conn} do
    account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, name: "Nubank"})
    statement = statement_fixture(%{account: account})

    {:ok, view, _html} = live(conn, ~p"/statements")

    html =
      view
      |> element("tr", "Nubank")
      |> render_click()

    assert html =~ "Nubank"
    assert html =~ statement.source_file
    assert html =~ "Fatura em aberto"
  end

  test "overview shows a Pendente badge for a pending statement", %{conn: conn} do
    account = CashLens.AccountsFixtures.account_fixture(%{is_credit_card: true, name: "Amazon"})

    statement_fixture(%{
      account: account,
      due_date: nil,
      total_a_pagar: Decimal.new("3.40")
    })

    {:ok, _view, html} = live(conn, ~p"/statements")
    assert html =~ "Pendente"
  end

  test "redirect from old path", %{conn: conn} do
    conn = get(conn, ~p"/credit_card_links")
    assert redirected_to(conn) == ~p"/statements"
  end
end
