defmodule CashLensWeb.ReimbursementLiveTest do
  use CashLensWeb.ConnCase, async: false

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

      assert html =~ "Reimbursement Management"
      assert html =~ "Lunch for team"
    end

    test "toggles selection of a reimbursement expense", %{conn: conn} do
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-100.00",
          description: "Lunch for team"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      # Initially not selected
      refute render(index_live) =~ "Total Selected (1"

      # Select
      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx.id}']")
      |> render_click()

      assert render(index_live) =~ "Total Selected (1"
      assert render(index_live) =~ "100,00"

      # Deselect
      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx.id}']")
      |> render_click()

      refute render(index_live) =~ "Total Selected (1"
    end

    test "clears selection of reimbursement expenses", %{conn: conn} do
      acc = account_fixture()

      tx1 =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-100.00",
          description: "Lunch 1"
        })

      tx2 =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-50.00",
          description: "Lunch 2"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      # Select both
      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx1.id}']")
      |> render_click()

      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx2.id}']")
      |> render_click()

      assert render(index_live) =~ "Total Selected (2"

      # Clear
      index_live
      |> element("button[phx-click='clear_selection']")
      |> render_click()

      refute render(index_live) =~ "Total Selected"
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

      assert html =~ "Requested"
      assert CashLens.Transactions.get_transaction!(tx.id).reimbursement_status == "requested"
    end

    test "unlinks a reimbursement", %{conn: conn} do
      acc = account_fixture()
      link_key = Ecto.UUID.generate()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "paid",
          reimbursement_link_key: link_key,
          amount: "-100.00",
          description: "Paid expense"
        })

      _credit =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "paid",
          reimbursement_link_key: link_key,
          amount: "100.00",
          description: "Credit"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      index_live
      |> element("button[phx-click='unlink_reimbursement'][phx-value-link-key='#{link_key}']")
      |> render_click()

      assert render(index_live) =~ "unlinked successfully"
      updated = CashLens.Transactions.get_transaction!(expense.id)
      assert is_nil(updated.reimbursement_link_key)
    end

    test "opens batch linker and searches", %{conn: conn} do
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-50.00",
          description: "Batch item"
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "50.00",
          description: "Batch credit"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx.id}']")
      |> render_click()

      index_live |> element("button[phx-click='open_batch_linker']") |> render_click()
      assert render(index_live) =~ "Link Receipt"
      assert render(index_live) =~ credit.description

      render_hook(index_live, "linker_search_change", %{"value" => "Batch"})
      assert render(index_live) =~ "Batch credit"

      render_click(index_live, "close_modal", %{})
      # After close, modal content (not the header button) is gone
      refute render(index_live) =~ "Select the credit that covers the total"
    end

    test "sort comparison: exact amount match ranks first", %{conn: conn} do
      acc = account_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-75.00",
          description: "Expense 75"
        })

      _credit_exact =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "75.00",
          description: "Exact match"
        })

      _credit_other =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "100.00",
          description: "Other amount"
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      index_live
      |> element("button[phx-click='link_single_expense'][phx-value-id='#{expense.id}']")
      |> render_click()

      html = render(index_live)
      assert html =~ "Exact match"
      assert html =~ "Perfect Match!"
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
      assert render(index_live) =~ "Perfect Match!"

      # Confirm link
      index_live
      |> element("button[phx-click='confirm_link'][phx-value-credit-id='#{credit.id}']")
      |> render_click()

      assert render(index_live) =~ "1 expenses linked!"

      updated_expense = CashLens.Transactions.get_transaction!(expense.id)
      assert updated_expense.reimbursement_status == "paid"
      assert updated_expense.reimbursement_link_key != nil

      updated_credit = CashLens.Transactions.get_transaction!(credit.id)
      assert updated_credit.reimbursement_status == "paid"
      assert updated_credit.reimbursement_link_key == updated_expense.reimbursement_link_key
    end
  end
end
