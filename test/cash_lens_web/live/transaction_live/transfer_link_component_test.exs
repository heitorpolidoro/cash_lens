defmodule CashLensWeb.TransactionLive.TransferLinkComponentTest do
  use CashLensWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  alias CashLens.Transactions

  test "linking a transfer", %{conn: conn} do
    acc1 = account_fixture()
    acc2 = account_fixture()
    tx1 = transaction_fixture(account_id: acc1.id, amount: "100.00")
    tx2 = transaction_fixture(account_id: acc2.id, amount: "-100.00")

    {:ok, index_live, _html} = live(conn, ~p"/transactions")

    index_live |> render_click("open_transfer_link", %{"id" => tx1.id})
    assert render(index_live) =~ "Link Transfer"

    index_live
    |> element("button[phx-click='link_transfer'][phx-value-pair-id='#{tx2.id}']")
    |> render_click()

    assert render(index_live) =~ "Transfer linked successfully!"

    assert Transactions.get_transaction!(tx1.id).transfer_key != nil

    assert Transactions.get_transaction!(tx1.id).transfer_key ==
             Transactions.get_transaction!(tx2.id).transfer_key
  end

  test "quick transfer creation", %{conn: conn} do
    acc1 = account_fixture()
    acc2 = account_fixture()
    # Slug will be "transfer"
    category_fixture(name: "transfer")
    tx1 = transaction_fixture(account_id: acc1.id, amount: "100.00", description: "From acc1")

    {:ok, index_live, _html} = live(conn, ~p"/transactions")

    index_live |> render_click("open_transfer_link", %{"id" => tx1.id})
    index_live |> element("button[phx-click='open_quick_transfer']") |> render_click()

    assert render(index_live) =~ "Create Transfer Pair"

    index_live
    |> element("#quick-transfer-form")
    |> render_submit(%{
      "account_id" => acc2.id,
      "description" => "To acc2",
      "date" => tx1.date,
      "amount" => "-100.00"
    })

    assert render(index_live) =~ "Transfer pair created and linked!"

    # Verify new transaction
    txs = Transactions.list_transactions(%{"account_id" => acc2.id})
    assert Enum.any?(txs, fn tx -> tx.description == "To acc2" and tx.transfer_key != nil end)
  end

  test "empty pending transfers", %{conn: conn} do
    tx = transaction_fixture(amount: "100.00")

    {:ok, index_live, _html} = live(conn, ~p"/transactions")
    index_live |> render_click("open_transfer_link", %{"id" => tx.id})

    assert render(index_live) =~ "No matching pair found for this transfer"
  end
end
