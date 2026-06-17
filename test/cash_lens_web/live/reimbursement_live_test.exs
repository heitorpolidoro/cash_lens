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

      assert html =~ "Gerenciamento de Reembolsos"
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
      refute render(index_live) =~ "Total Selecionado (1"

      # Select
      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx.id}']")
      |> render_click()

      assert render(index_live) =~ "Total Selecionado (1"
      assert render(index_live) =~ "100,00"

      # Deselect
      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx.id}']")
      |> render_click()

      refute render(index_live) =~ "Total Selecionado (1"
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

      assert render(index_live) =~ "Total Selecionado (2"

      # Clear
      index_live
      |> element("button[phx-click='clear_selection']")
      |> render_click()

      refute render(index_live) =~ "Total Selecionado"
    end

    test "marks a reimbursement as requested", %{conn: conn} do
      acc = account_fixture()

      tx =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-120.50",
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

      assert render(index_live) =~ "desvinculado com sucesso"
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
          description: "Batch item",
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "50.00",
          description: "Batch credit",
          date: ~D[2026-03-20]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      index_live
      |> element("input[phx-click='toggle_selection'][phx-value-id='#{tx.id}']")
      |> render_click()

      index_live |> element("button[phx-click='open_batch_linker']") |> render_click()
      assert render(index_live) =~ "Vincular Recebimento"
      assert render(index_live) =~ credit.description

      render_hook(index_live, "linker_search_change", %{"value" => "Batch"})
      assert render(index_live) =~ "Batch credit"

      render_click(index_live, "close_modal", %{})
      # After close, modal content (not the header button) is gone
      refute render(index_live) =~ "Selecione um ou mais créditos"
    end

    test "sort comparison: exact amount match ranks first", %{conn: conn} do
      acc = account_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-75.00",
          description: "Expense 75",
          date: ~D[2026-02-23]
        })

      credit_exact =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "75.00",
          description: "Exact match",
          date: ~D[2026-03-20]
        })

      _credit_other =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "100.00",
          description: "Other amount",
          date: ~D[2026-03-20]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      index_live
      |> element("button[phx-click='link_single_expense'][phx-value-id='#{expense.id}']")
      |> render_click()

      html = render(index_live)
      assert html =~ "Exact match"

      # Selecting the exact-amount credit reveals the perfect-match indicator
      render_click(index_live, "toggle_credit", %{"credit-id" => credit_exact.id})
      assert render(index_live) =~ "Match Perfeito!"
    end

    test "links an expense with a credit", %{conn: conn} do
      acc = account_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-150.00",
          description: "Travel expense",
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "150.00",
          description: "Company refund",
          date: ~D[2026-03-20]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      # Click to link single expense
      index_live
      |> element("button[phx-click='link_single_expense'][phx-value-id='#{expense.id}']")
      |> render_click()

      # Now the modal is open, we can see the credit
      assert render(index_live) =~ "Company refund"

      # Selecting the matching credit reveals the perfect-match indicator
      render_click(index_live, "toggle_credit", %{"credit-id" => credit.id})
      assert render(index_live) =~ "Match Perfeito!"

      # Confirm link
      index_live
      |> element("button[phx-click='confirm_link']")
      |> render_click()

      assert render(index_live) =~ "1 crédito(s) vinculado(s) à despesa!"

      updated_expense = CashLens.Transactions.get_transaction!(expense.id)
      assert updated_expense.reimbursement_status == "paid"
      assert updated_expense.reimbursement_link_key != nil

      updated_credit = CashLens.Transactions.get_transaction!(credit.id)
      assert updated_credit.reimbursement_status == "paid"
      assert updated_credit.reimbursement_link_key == updated_expense.reimbursement_link_key
    end

    test "confirms a suggested reimbursement pair", %{conn: conn} do
      acc = account_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-45.00",
          description: "Suggest expense",
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "45.00",
          description: "Suggest credit",
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      assert render(index_live) =~ "Pares Sugeridos"
      assert render(index_live) =~ "Suggest expense"
      assert render(index_live) =~ "Suggest credit"

      index_live
      |> element(
        "button[phx-click='confirm_pair'][phx-value-a='#{expense.id}'][phx-value-b='#{credit.id}']"
      )
      |> render_click()

      assert render(index_live) =~ "Reembolso vinculado com sucesso!"
      assert CashLens.Transactions.get_transaction!(expense.id).reimbursement_status == "paid"
      assert CashLens.Transactions.get_transaction!(credit.id).reimbursement_status == "paid"
    end

    test "confirms all suggested reimbursement pairs", %{conn: conn} do
      acc = account_fixture()

      expense1 =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-60.00",
          description: "Suggest expense 1",
          date: ~D[2026-02-23]
        })

      credit1 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "60.00",
          description: "Suggest credit 1",
          date: ~D[2026-02-24]
        })

      expense2 =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "requested",
          amount: "-80.00",
          description: "Suggest expense 2",
          date: ~D[2026-02-23]
        })

      credit2 =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "80.00",
          description: "Suggest credit 2",
          date: ~D[2026-02-25]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      assert render(index_live) =~ "Confirmar Todos"

      index_live
      |> element("button[phx-click='confirm_all']")
      |> render_click()

      assert render(index_live) =~ "2 reembolsos vinculados com sucesso!"
      assert CashLens.Transactions.get_transaction!(expense1.id).reimbursement_status == "paid"
      assert CashLens.Transactions.get_transaction!(credit1.id).reimbursement_status == "paid"
      assert CashLens.Transactions.get_transaction!(expense2.id).reimbursement_status == "paid"
      assert CashLens.Transactions.get_transaction!(credit2.id).reimbursement_status == "paid"
    end

    test "ignores suggestions from accounts that do not accept import", %{conn: conn} do
      acc_no_import = account_fixture(%{accepts_import: false})
      acc_import = account_fixture(%{accepts_import: true})

      _expense =
        transaction_fixture(%{
          account_id: acc_no_import.id,
          reimbursement_status: "pending",
          amount: "-35.00",
          description: "No import expense",
          date: ~D[2026-02-23]
        })

      _credit =
        transaction_fixture(%{
          account_id: acc_import.id,
          amount: "35.00",
          description: "Import credit",
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      assert render(index_live) =~ "0 pares sugeridos"
      refute render(index_live) =~ "Confirmar"
    end

    test "ignores suggestions where the expense is categorized as transfer", %{conn: conn} do
      acc = account_fixture()
      category = CashLens.CategoriesFixtures.category_fixture(%{name: "Transfer"})

      _expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-40.00",
          description: "Transfer expense",
          date: ~D[2026-02-23],
          category_id: category.id
        })

      _credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "40.00",
          description: "Reimbursement credit",
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      assert render(index_live) =~ "0 pares sugeridos"
      refute render(index_live) =~ "Confirmar"
    end

    test "sorts unmatched reimbursement expenses in ascending order by date", %{conn: conn} do
      acc = account_fixture()

      _expense_middle =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-10.00",
          description: "Middle Expense",
          date: ~D[2026-02-20]
        })

      _expense_earliest =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-20.00",
          description: "Earliest Expense",
          date: ~D[2026-02-15]
        })

      _expense_latest =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: "pending",
          amount: "-30.00",
          description: "Latest Expense",
          date: ~D[2026-02-25]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")
      html = render(index_live)

      # The order should be Earliest Expense, then Middle Expense, then Latest Expense
      assert html =~ ~r/Earliest Expense.*Middle Expense.*Latest Expense/s
    end

    test "suggests reimbursement pairs even if neither transaction has reimbursement_status set",
         %{conn: conn} do
      acc = account_fixture()

      _expense =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: nil,
          amount: "-22.75",
          description: "Anuidade",
          date: ~D[2025-11-25]
        })

      _credit =
        transaction_fixture(%{
          account_id: acc.id,
          reimbursement_status: nil,
          amount: "22.75",
          description: "Desconto Anuidade",
          date: ~D[2025-11-25]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")
      html = render(index_live)

      assert html =~ "1 pares sugeridos"
      assert html =~ "Anuidade"
      assert html =~ "Desconto Anuidade"
    end

    test "rejecting/ignoring a suggested reimbursement pair", %{conn: conn} do
      acc = account_fixture()

      expense =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "-50.00",
          description: "Reimburse expense",
          date: ~D[2026-02-23]
        })

      credit =
        transaction_fixture(%{
          account_id: acc.id,
          amount: "50.00",
          description: "Reimburse credit",
          date: ~D[2026-02-24]
        })

      {:ok, index_live, _html} = live(conn, ~p"/reimbursements")

      assert render(index_live) =~ "1 pares sugeridos"

      # Click "Ignorar"
      index_live
      |> element(
        "button[phx-click='reject_pair'][phx-value-a='#{expense.id}'][phx-value-b='#{credit.id}']"
      )
      |> render_click()

      assert render(index_live) =~ "Sugestão de reembolso ignorada."
      assert render(index_live) =~ "0 pares sugeridos"
    end
  end
end
