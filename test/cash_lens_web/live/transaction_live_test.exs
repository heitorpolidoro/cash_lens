defmodule CashLensWeb.TransactionLiveTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  @create_attrs %{
    date: Date.utc_today(),
    description: "some description",
    amount: "120.5"
  }
  @update_attrs %{
    date: Date.utc_today(),
    description: "some updated description",
    amount: "456.7"
  }
  @invalid_attrs %{date: nil, description: nil, amount: nil}

  defp create_transaction(_) do
    transaction = transaction_fixture()
    %{transaction: transaction}
  end

  describe "Index" do
    setup [:create_transaction]

    test "lists all transactions", %{conn: conn, transaction: transaction} do
      {:ok, _index_live, html} = live(conn, ~p"/transactions")

      assert html =~ "Transações"
      assert html =~ transaction.description
    end

    test "saves new transaction", %{conn: conn} do
      account = account_fixture()
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      assert {:ok, form_live, html} =
               index_live
               |> element("a[href='/transactions/new']")
               |> render_click()
               |> follow_redirect(conn, ~p"/transactions/new")

      assert html =~ "New Transaction"

      assert form_live
             |> form("#transaction-form", transaction: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, _index_live, html} =
               form_live
               |> form("#transaction-form",
                 transaction: Map.put(@create_attrs, :account_id, account.id)
               )
               |> render_submit()
               |> follow_redirect(conn, ~p"/transactions")

      assert html =~ "Transaction created successfully"
      assert html =~ "some description"
    end

    test "updates transaction in listing", %{conn: conn, transaction: transaction} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      assert {:ok, form_live, html} =
               index_live
               |> element("#transactions-#{transaction.id} a[aria-label='Edit']")
               |> render_click()
               |> follow_redirect(conn, ~p"/transactions/#{transaction}/edit")

      assert html =~ "Edit Transaction"

      assert form_live
             |> form("#transaction-form", transaction: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, _index_live, html} =
               form_live
               |> form("#transaction-form", transaction: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/transactions")

      assert html =~ "Transaction updated successfully"
      assert html =~ "some updated description"
    end

    test "deletes transaction in listing", %{conn: conn, transaction: transaction} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      assert index_live
             |> element("#transactions-#{transaction.id} button[aria-label='Excluir']")
             |> render_click()

      render_click(index_live, "delete", %{"id" => transaction.id})
      refute has_element?(index_live, "#transactions-#{transaction.id}")
    end
  end

  describe "Show" do
    setup [:create_transaction]

    test "displays transaction", %{conn: conn, transaction: transaction} do
      {:ok, _show_live, html} = live(conn, ~p"/transactions/#{transaction}")

      assert html =~ "Show Transaction"
      assert html =~ transaction.description
    end

    test "updates transaction and returns to show", %{conn: conn, transaction: transaction} do
      {:ok, show_live, _html} = live(conn, ~p"/transactions/#{transaction}")

      {:ok, form_live, _html} =
        show_live
        |> element("a", "Edit transaction")
        |> render_click()
        |> follow_redirect(conn, ~p"/transactions/#{transaction}/edit?return_to=show")

      assert render(form_live) =~ "Edit Transaction"

      assert form_live
             |> form("#transaction-form", transaction: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, _show_live, html} =
               form_live
               |> form("#transaction-form", transaction: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/transactions/#{transaction}")

      assert html =~ "Transaction updated successfully"
      assert html =~ "some updated description"
    end
  end

  describe "Modals, Linking and Transfers" do
    setup [:create_transaction]

    test "toggles sorting and views", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions")
      live |> element("button[phx-click='toggle_sort']") |> render_click()
      live |> element("button[phx-value-type='credit']") |> render_click()
      live |> element("button[phx-click='toggle_unmatched']") |> render_click()
      assert render(live) =~ "Transações"
    end

    test "handles reimbursement linking", %{conn: conn, transaction: _tx} do
      account = account_fixture()

      expense =
        transaction_fixture(amount: "-100.00", account_id: account.id, description: "Lunch")

      reimb_cat = category_fixture(%{name: "Reimbursable", slug: "reimbursable"})

      {:ok, expense} =
        CashLens.Transactions.update_transaction(expense, %{
          category_id: reimb_cat.id,
          reimbursement_status: "pending"
        })

      credit =
        transaction_fixture(
          amount: "100.00",
          account_id: account.id,
          date: expense.date,
          description: "Refund"
        )

      {:ok, live, _html} = live(conn, ~p"/transactions")

      live
      |> element("button[phx-click='open_reimbursement_link'][phx-value-id='#{credit.id}']")
      |> render_click()

      assert render(live) =~ "Vincular Reembolso"

      live
      |> element("button[phx-click='link_reimbursement'][phx-value-expense-id='#{expense.id}']")
      |> render_click()

      assert render(live) =~ "Reembolso vinculado"
    end

    test "handles transfer linking and creation", %{conn: conn, transaction: _tx} do
      account = account_fixture()
      transfer_cat = category_fixture(%{name: "Transfer", slug: "transfer"})

      tx =
        transaction_fixture(
          amount: "-50.00",
          account_id: account.id,
          category_id: transfer_cat.id
        )

      target_account = account_fixture(name: "Target")

      {:ok, live, _html} = live(conn, ~p"/transactions")

      live
      |> element("button[phx-click='open_transfer_link'][phx-value-id='#{tx.id}']")
      |> render_click()

      assert render(live) =~ "Vincular Transferência"
      live |> element("button[phx-click='open_quick_transfer']") |> render_click()

      assert render(live) =~ "Criar Par da Transferência"

      live
      |> form("#quick-transfer-form", %{
        "account_id" => target_account.id,
        "description" => "Transfer",
        "date" => Date.to_string(tx.date),
        "amount" => "50.0"
      })
      |> render_submit()

      assert render(live) =~ "Par da transferência criado"
    end

    test "deletes all transactions", %{conn: conn} do
      transaction_fixture()
      {:ok, live, _html} = live(conn, ~p"/transactions")
      live |> element("button[phx-click='confirm_delete_all']") |> render_click()
      render_click(live, "delete_all")
      # Check that the stream is empty (no tr elements with id starting with transactions-)
      refute render(live) =~ "id=\"transactions-"
    end

    test "balance correction", %{conn: conn} do
      account = account_fixture()
      transaction_fixture(account_id: account.id)
      {:ok, live, _html} = live(conn, ~p"/transactions")

      # Select account first via the form
      live |> form("#transaction-filters", %{"account_id" => account.id}) |> render_change()

      # The phx-click is on a div with class "stats"
      live |> element(".stats", "Saldo") |> render_click()

      assert has_element?(live, "#balance-correction-modal")

      live
      |> form("#balance-correction-form", %{
        "new_balance" => "1000",
        "adjustment_type" => "rendimentos"
      })
      |> render_submit()

      assert render(live) =~ "Saldo ajustado com sucesso"
    end

    test "month navigation", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions")

      # Next month
      live |> element("button[phx-click='next_month']") |> render_click()
      # Prev month
      live |> element("button[phx-click='prev_month']") |> render_click()

      assert render(live) =~ "Transações"
    end

    test "auto-categorizes all transactions", %{conn: conn} do
      category_fixture(%{name: "Streaming", keywords: "NETFLIX"})
      transaction_fixture(%{description: "NETFLIX", category_id: nil})

      {:ok, live, _html} = live(conn, ~p"/transactions")
      live |> element("button", "Auto-Categorizar") |> render_click()

      assert render(live) =~ "Regras aplicadas!"
    end

    test "filters by search and clear filters", %{conn: conn} do
      transaction_fixture(%{description: "SearchTarget"})
      {:ok, live, _html} = live(conn, ~p"/transactions")

      live |> form("#transaction-filters", %{"search" => "SearchTarget"}) |> render_change()
      assert render(live) =~ "SearchTarget"

      live |> element("button[phx-click='clear_filters']") |> render_click()
      assert render(live) =~ "Transações"
    end

    test "toggles pending transactions", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions")
      live |> element("button[phx-click='toggle_pending']") |> render_click()
      assert render(live) =~ "Pendentes"
    end

    test "handles pagination via infinite scroll", %{conn: conn} do
      for i <- 1..60, do: transaction_fixture(%{description: "Pagination #{i}"})
      {:ok, live, _html} = live(conn, ~p"/transactions")

      # Trigger infinite scroll event
      render_hook(live, "load-more", %{"page" => "1"})
      assert render(live) =~ "Pagination"
    end
  end
end
