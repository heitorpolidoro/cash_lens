defmodule CashLensWeb.ReimbursementLiveTest do
  use CashLensWeb.ConnCase
  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.AccountsFixtures

  describe "Index" do
    test "lists reimbursements", %{conn: conn} do
      acc = account_fixture()

      transaction_fixture(%{
        account_id: acc.id,
        reimbursement_status: "pending",
        amount: "-100.00",
        description: "Lunch for team"
      })

      {:ok, _index_live, html} = live(conn, ~p"/reimbursements")

      assert html =~ "Gestão de Reembolsos"
      assert html =~ "Lunch for team"
    end

    test "marks a reimbursement as requested", %{conn: conn} do
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          description: "Pending item"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      html =
        index_live
        |> element("button[phx-click='mark_requested'][phx-value-id='#{tx.id}']")
        |> render_click()

      assert html =~ "Solicitado"
      assert CashLens.Transactions.get_transaction!(tx.id).reimbursement_status == "requested"
    end

    test "links an expense with a credit", %{conn: conn} do
      acc = account_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-150.00",
          description: "Travel expense"
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "150.00",
          description: "Company refund"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      # Click to link single expense
      index_live
      |> element("button[phx-click='link_single_expense'][phx-value-id='#{expense.id}']")
      |> render_click()

      # Now the modal is open, we can see the credit
      assert render(index_live) =~ "Company refund"
      assert render(index_live) =~ "Match Perfeito!"

      # Confirm link
      index_live
      |> element("button[phx-click='confirm_link'][phx-value-credit-id='#{credit.id}']")
      |> render_click()

      assert render(index_live) =~ "1 despesas vinculadas!"

      updated_expense = CashLens.Transactions.get_transaction!(expense.id)
      assert updated_expense.reimbursement_status == "paid"
      assert updated_expense.reimbursement_link_key != nil

      updated_credit = CashLens.Transactions.get_transaction!(credit.id)
      assert updated_credit.reimbursement_status == "paid"
      assert updated_credit.reimbursement_link_key == updated_expense.reimbursement_link_key
    end
  end
end
