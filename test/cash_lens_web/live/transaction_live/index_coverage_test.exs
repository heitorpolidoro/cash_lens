defmodule CashLensWeb.TransactionLive.IndexCoverageTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Transactions

  describe "Index coverage" do
    test "unmark_reimbursable with link key", %{conn: conn} do
      key = Ecto.UUID.generate()
      tx1 = transaction_fixture(reimbursement_link_key: key, reimbursement_status: "linked")
      tx2 = transaction_fixture(reimbursement_link_key: key, reimbursement_status: "linked")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live
      |> element("#transactions-#{tx1.id} button[phx-click='unmark_reimbursable']")
      |> render_click()

      updated1 = Transactions.get_transaction!(tx1.id)
      updated2 = Transactions.get_transaction!(tx2.id)

      assert is_nil(updated1.reimbursement_link_key)
      assert is_nil(updated1.reimbursement_status)
      assert is_nil(updated2.reimbursement_link_key)
      assert is_nil(updated2.reimbursement_status)
    end

    test "mark_reimbursable", %{conn: conn} do
      tx = transaction_fixture()
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "mark_reimbursable", %{"id" => tx.id})

      assert Transactions.get_transaction!(tx.id).reimbursement_status == "pending"
    end

    test "open_quick_category", %{conn: conn} do
      tx = transaction_fixture(description: "netflix subscription")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "open_quick_category", %{"name" => tx.description, "id" => tx.id})

      # The modal title is inside the quick-category-modal-modal-content
      assert render(index_live) =~ "New Category"
      assert render(index_live) =~ "organize your entries"
    end

    test "update_category and bulk confirmation", %{conn: conn} do
      cat = category_fixture(name: "Food")
      tx1 = transaction_fixture(description: "Restaurante A")
      tx2 = transaction_fixture(description: "Restaurante A")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "update_category", %{
        "transaction_id" => tx1.id,
        "category_id" => cat.id
      })

      html = render(index_live)
      assert html =~ "Bulk Categorization"

      index_live |> element("button[phx-click='apply_bulk_category']") |> render_click()

      assert Transactions.get_transaction!(tx2.id).category_id == cat.id
      assert render(index_live) =~ "Bulk categorized!"
    end

    test "save_balance_correction ajuste_inicial", %{conn: conn} do
      account = account_fixture(balance: "100.00")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> form("#transaction-filters", %{"account_id" => account.id}) |> render_change()
      index_live |> element(".stats", "Balance") |> render_click()

      render_click(index_live, "update_diff", %{"value" => "150.00"})
      assert render(index_live) =~ "+R$ 50,00"

      index_live
      |> form("#balance-correction-form", %{
        "new_balance" => "150.00",
        "adjustment_type" => "ajuste_inicial"
      })
      |> render_submit()

      updated_account = CashLens.Accounts.get_account!(account.id)
      assert Decimal.equal?(updated_account.balance, Decimal.new("150.00"))
    end

    test "handle_info category_created with target_transaction_id", %{conn: conn} do
      tx = transaction_fixture(description: "New Shop")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      cat = category_fixture(name: "Shopping")

      send(index_live.pid, {:category_created, cat, tx.id})

      html = render(index_live)
      assert Transactions.get_transaction!(tx.id).category_id == cat.id
      assert html =~ "Category created!"
    end

    test "toggle_type filter", %{conn: conn} do
      transaction_fixture(amount: "100.00", description: "Credit-TX")
      transaction_fixture(amount: "-50.00", description: "Debit-TX")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> element("button[phx-value-type='credit']") |> render_click()
      assert render(index_live) =~ "Credit-TX"
      refute render(index_live) =~ "Debit-TX"

      index_live |> element("button[phx-value-type='credit']") |> render_click()
      assert render(index_live) =~ "Credit-TX"
      assert render(index_live) =~ "Debit-TX"
    end

    test "handle_info import errors", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")
      send(index_live.pid, {:import_error, "Invalid format"})
      assert render(index_live) =~ "Import error: Invalid format"
    end

    test "handle_info category updates/deletes", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")
      cat = category_fixture()

      send(index_live.pid, {:category_updated, cat})
      render(index_live)
      send(index_live.pid, {:category_deleted, cat})
      render(index_live)

      assert render(index_live) =~ "Transactions"
    end

    test "close_modal event", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      render_click(index_live, "open_import")
      # Check for specific modal content
      assert render(index_live) =~ "Select Destination Account"

      render_click(index_live, "close_modal")
      # Content should be gone
      refute render(index_live) =~ "Select Destination Account"
    end
  end
end
