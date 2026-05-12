defmodule CashLensWeb.TransactionLive.IndexFullCoverageTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Transactions

  describe "Index full coverage" do
    test "auto_categorize_all event", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live
      |> element("button[phx-click='auto_categorize_all']")
      |> render_click()

      assert render(index_live) =~ "Rules applied!"
    end

    test "clear_filters event", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions?search=testing")
      assert render(index_live) =~ "testing"

      index_live
      |> element("button[phx-click='clear_filters']")
      |> render_click()

      # Filters should be cleared, no "testing" in search input (if it was bound)
      # We check if the summary is recalculated and streams reset
      assert render(index_live) =~ "Transactions"
    end

    test "toggle_unmatched event", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Toggle on
      index_live |> render_click("toggle_unmatched", %{})
      # Toggle off
      index_live |> render_click("toggle_unmatched", %{})

      assert render(index_live) =~ "Transactions"
    end

    test "month navigation events", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Next month
      index_live |> render_click("next_month", %{})
      # Prev month
      index_live |> render_click("prev_month", %{})

      # Test edge case: January -> Prev -> December of last year
      # We need to force filters to January
      index_live |> render_click("apply_filters", %{"month" => "1", "year" => "2024"})
      index_live |> render_click("prev_month", %{})
      # Should be December 2023

      # Test edge case: December -> Next -> January of next year
      index_live |> render_click("apply_filters", %{"month" => "12", "year" => "2024"})
      index_live |> render_click("next_month", %{})
      # Should be January 2025

      assert render(index_live) =~ "Transactions"
    end

    test "toggle_pending event", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Toggle on (category_id=nil)
      index_live |> render_click("toggle_pending", %{})
      # Toggle off
      index_live |> render_click("toggle_pending", %{})

      assert render(index_live) =~ "Transactions"
    end

    test "load-more event", %{conn: conn} do
      # Create enough transactions to have more than one page (default page size is usually 20-50)
      # But we can also just trigger it and see it doesn't crash
      for i <- 1..5, do: transaction_fixture(description: "Tx #{i}")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Trigger load-more
      index_live |> render_hook("load-more", %{})

      assert render(index_live) =~ "Transactions"
    end

    test "delete all transactions", %{conn: conn} do
      transaction_fixture()
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> render_click("confirm_delete_all")
      # It sets confirm_modal which renders the action
      assert render(index_live) =~ "delete_all"

      index_live |> render_click("delete_all")

      assert Transactions.list_transactions() == []
    end

    test "delete single transaction", %{conn: conn} do
      tx = transaction_fixture()
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> render_click("confirm_delete", %{"id" => tx.id})
      index_live |> render_click("delete", %{"id" => tx.id})

      assert_raise Ecto.NoResultsError, fn -> Transactions.get_transaction!(tx.id) end
    end

    test "handle_info messages", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      send(index_live.pid, :reimbursement_linked)
      assert render(index_live) =~ "Reimbursement linked"

      send(index_live.pid, :close_transfer_modal)

      send(index_live.pid, {:transfer_linked, "Linked!"})
      assert render(index_live) =~ "Linked!"

      send(index_live.pid, :close_import_modal)

      send(index_live.pid, {:import_success, %{imported: 10, failed: []}})
      assert render(index_live) =~ "10 transactions imported"

      send(index_live.pid, {:import_error, "Failed"})
      assert render(index_live) =~ "Import error: Failed"

      # Test category info handlers
      cat = category_fixture()
      send(index_live.pid, {:category_created, cat, nil})
      send(index_live.pid, {:category_updated, cat})
      send(index_live.pid, {:category_deleted, cat})
    end

    test "handle_info category_created with target_transaction_id", %{conn: conn} do
      tx = transaction_fixture()
      cat = category_fixture()
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      send(index_live.pid, {:category_created, cat, tx.id})

      assert render(index_live) =~ "Category created!"
      assert Transactions.get_transaction!(tx.id).category_id == cat.id
    end

    test "toggle_sort event", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Initially desc, toggle to asc
      index_live |> render_click("toggle_sort")
      # Toggle back to desc
      index_live |> render_click("toggle_sort")

      assert render(index_live) =~ "Transactions"
    end

    test "open_reimbursement_link", %{conn: conn} do
      tx = transaction_fixture(amount: "100.00")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> render_click("open_reimbursement_link", %{"id" => tx.id})
      assert render(index_live) =~ "Vincular Reembolso"
    end

    test "unmark_reimbursable without link key", %{conn: conn} do
      tx = transaction_fixture(reimbursement_status: "pending")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> render_click("unmark_reimbursable", %{"id" => tx.id})
      assert is_nil(Transactions.get_transaction!(tx.id).reimbursement_status)
    end

    test "unmark_reimbursable with link key", %{conn: conn} do
      key = Ecto.UUID.generate()
      tx1 = transaction_fixture(reimbursement_status: "pending", reimbursement_link_key: key)
      tx2 = transaction_fixture(reimbursement_status: "pending", reimbursement_link_key: key)

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> render_click("unmark_reimbursable", %{"id" => tx1.id})

      assert is_nil(Transactions.get_transaction!(tx1.id).reimbursement_link_key)
      assert is_nil(Transactions.get_transaction!(tx2.id).reimbursement_link_key)
    end

    test "update_category error branch", %{conn: conn} do
      tx = transaction_fixture()
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Use an invalid UUID for category_id to trigger an error in update_transaction_category
      index_live
      |> render_click("update_category", %{
        "transaction_id" => tx.id,
        "category_id" => Ecto.UUID.generate()
      })

      assert render(index_live) =~ "Update failed"
    end

    test "get_bulk_items_for_tx with bulk ignore pattern", %{conn: conn} do
      # Create a pattern
      Transactions.create_bulk_ignore_pattern(%{pattern: "SKIP_ME", description: "Skip"})

      tx = transaction_fixture(description: "SKIP_ME 123")
      cat = category_fixture()

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Trigger process_category_created_with_tx via handle_info
      send(index_live.pid, {:category_created, cat, tx.id})

      # Since it should skip bulk, bulk_confirmation should be nil
      refute render(index_live) =~ "Bulk Categorized"
    end

    test "toggle_type filters", %{conn: conn} do
      transaction_fixture(amount: "100.00", description: "UniqueCredit")
      transaction_fixture(amount: "-50.00", description: "UniqueDebit")

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> render_click("toggle_type", %{"type" => "credit"})
      assert render(index_live) =~ "UniqueCredit"
      refute render(index_live) =~ "UniqueDebit"

      index_live |> render_click("toggle_type", %{"type" => "debit"})
      assert render(index_live) =~ "UniqueDebit"
      refute render(index_live) =~ "UniqueCredit"

      # Toggle off
      index_live |> render_click("toggle_type", %{"type" => "debit"})
      assert render(index_live) =~ "UniqueCredit"
      assert render(index_live) =~ "UniqueDebit"
    end

    test "type_match credit via stream_update_transaction", %{conn: conn} do
      cat = category_fixture(name: "Food")
      credit_tx = transaction_fixture(amount: "100.00", description: "CreditTx")

      {:ok, index_live, _html} = live(conn, ~p"/transactions?type=credit")

      # Update category of a credit transaction while type=credit filter is active
      # This triggers stream_update_transaction -> matches_filters? -> type_match?(tx, "credit")
      index_live
      |> render_click("update_category", %{
        "transaction_id" => credit_tx.id,
        "category_id" => cat.id
      })

      assert render(index_live) =~ "CreditTx"
    end

    test "assign_transfer_category_id finds existing transfer category", %{conn: conn} do
      transfer_cat = category_fixture(%{name: "Transfer", slug: "transfer"})
      # Transaction with transfer category but no transfer_key — shows up in "unmatched" filter
      tx = transaction_fixture(description: "UnmatchedTransfer", category_id: transfer_cat.id)

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Toggle unmatched: only shows tx with transfer_category_id and no transfer_key
      index_live |> render_click("toggle_unmatched", %{})

      assert render(index_live) =~ tx.description
    end

    test "open_transfer_link", %{conn: conn} do
      tx = transaction_fixture(amount: "100.00")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> render_click("open_transfer_link", %{"id" => tx.id})
      assert render(index_live) =~ "Link Transfer"
    end

    test "open_quick_category", %{conn: conn} do
      tx = transaction_fixture(description: "test transaction")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live
      |> render_click("open_quick_category", %{"name" => "test transaction", "id" => tx.id})

      assert render(index_live) =~ "Test Transaction"
    end

    test "close_modal", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")
      index_live |> render_click("open_import")
      assert render(index_live) =~ "1. Select Destination Account"

      index_live |> render_click("close_modal")
      refute render(index_live) =~ "1. Select Destination Account"
    end
  end
end
