defmodule CashLensWeb.TransactionLive.ReimbursementLinkComponentTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Transactions

  test "linking a reimbursement", %{conn: conn} do
    credit = transaction_fixture(amount: "100.00", description: "Credit")
    expense = transaction_fixture(amount: "-100.00", description: "Expense")

    {:ok, index_live, _html} = live(conn, ~p"/transactions")

    # Open modal
    index_live |> render_click("open_reimbursement_link", %{"id" => credit.id})
    assert render(index_live) =~ "Vincular Reembolso"
    assert render(index_live) =~ "Expense"

    # Link it
    index_live
    |> element("button[phx-click='link_reimbursement'][phx-value-expense-id='#{expense.id}']")
    |> render_click()

    assert render(index_live) =~ "Reembolso vinculado"

    updated_credit = Transactions.get_transaction!(credit.id)
    updated_expense = Transactions.get_transaction!(expense.id)

    assert updated_credit.reimbursement_status == "paid"
    assert updated_expense.reimbursement_status == "paid"
    assert updated_credit.reimbursement_link_key == updated_expense.reimbursement_link_key
  end

  test "search in reimbursement modal", %{conn: conn} do
    credit = transaction_fixture(amount: "100.00")
    _expense1 = transaction_fixture(amount: "-100.00", description: "Match")
    _expense2 = transaction_fixture(amount: "-100.00", description: "Hidden")

    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_reimbursement_link", %{"id" => credit.id})

    # Search for "Match"
    index_live
    |> element("input[phx-keyup='reimbursement_search_change']")
    |> render_keyup(%{"value" => "Match"})

    assert render(index_live) =~ "Match"

    # Check that "Hidden" is not in the modal content
    refute index_live |> element("#reimbursement-link-modal") |> render() =~ "Hidden"
  end

  test "empty search results", %{conn: conn} do
    credit = transaction_fixture(amount: "100.00")

    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_reimbursement_link", %{"id" => credit.id})

    index_live
    |> element("input[phx-keyup='reimbursement_search_change']")
    |> render_keyup(%{"value" => "non-existent"})

    assert render(index_live) =~ "Nenhuma despesa pendente de reembolso encontrada"
  end

  test "linking with category carry over", %{conn: conn} do
    cat = category_fixture()
    credit = transaction_fixture(amount: "100.00")
    expense = transaction_fixture(amount: "-100.00", category_id: cat.id)

    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_reimbursement_link", %{"id" => credit.id})

    index_live
    |> element("button[phx-click='link_reimbursement'][phx-value-expense-id='#{expense.id}']")
    |> render_click()

    assert Transactions.get_transaction!(credit.id).category_id == cat.id
  end
end
