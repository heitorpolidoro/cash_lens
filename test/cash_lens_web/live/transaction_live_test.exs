defmodule CashLensWeb.TransactionLiveTest do
  use CashLensWeb.ConnCase

  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  @create_attrs %{date: ~D[2026-02-23], description: "some description", amount: "120.5"}
  @update_attrs %{date: ~D[2026-02-24], description: "some updated description", amount: "456.7"}
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

    test "saves new transaction", %{conn: conn, transaction: transaction} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      {:ok, form_live, _html} =
        index_live
        |> element("a", "Nova Transação")
        |> render_click()
        |> follow_redirect(conn, ~p"/transactions/new")

      assert render(form_live) =~ "New Transaction"

      assert form_live
             |> form("#transaction-form", transaction: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, _index_live, html} =
               form_live
               |> form("#transaction-form",
                 transaction: Map.put(@create_attrs, :account_id, transaction.account_id)
               )
               |> render_submit()
               |> follow_redirect(conn, ~p"/transactions")

      assert html =~ "Transaction created successfully"
      assert html =~ "some description"
    end

    test "updates transaction in listing", %{conn: conn, transaction: transaction} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      {:ok, form_live, _html} =
        index_live
        |> element("#transactions-#{transaction.id} a[aria-label='Edit']")
        |> render_click()
        |> follow_redirect(conn, ~p"/transactions/#{transaction}/edit")

      assert render(form_live) =~ "Edit Transaction"

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

      assert render(index_live) =~ "Excluir Transação?"

      assert index_live |> element("button", "Sim, Apagar") |> render_click()
      refute has_element?(index_live, "#transactions-#{transaction.id}")
    end
  end

  describe "Filters & Boundary Conditions" do
    setup [:create_transaction]

    test "filters by search term", %{conn: conn, transaction: transaction} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      assert has_element?(index_live, "#transactions-#{transaction.id}")

      # Filter out
      index_live
      |> form("#transaction-filters", %{search: "non-existent-search"})
      |> render_change()

      refute has_element?(index_live, "#transactions-#{transaction.id}")

      # Filter in
      index_live
      |> form("#transaction-filters", %{search: transaction.description})
      |> render_change()

      assert has_element?(index_live, "#transactions-#{transaction.id}")
    end

    test "filters by account", %{conn: conn, transaction: transaction} do
      other_account = account_fixture(name: "Other Account")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      assert has_element?(index_live, "#transactions-#{transaction.id}")

      # Filter by other account
      index_live
      |> form("#transaction-filters", %{account_id: other_account.id})
      |> render_change()

      refute has_element?(index_live, "#transactions-#{transaction.id}")

      # Filter by correct account
      index_live
      |> form("#transaction-filters", %{account_id: transaction.account_id})
      |> render_change()

      assert has_element?(index_live, "#transactions-#{transaction.id}")
    end

    test "filters by month/year navigation", %{conn: conn} do
      # Create transactions in different months
      jan_tx = transaction_fixture(date: ~D[2026-01-15], description: "January Tx")
      feb_tx = transaction_fixture(date: ~D[2026-02-15], description: "February Tx")

      {:ok, index_live, _html} = live(conn, ~p"/transactions?month=2&year=2026")

      assert has_element?(index_live, "#transactions-#{feb_tx.id}")
      refute has_element?(index_live, "#transactions-#{jan_tx.id}")

      # Navigate to previous month
      index_live |> element("button[phx-click='prev_month']") |> render_click()

      # The UI updates the stream and filters
      assert has_element?(index_live, "#transactions-#{jan_tx.id}")
      refute has_element?(index_live, "#transactions-#{feb_tx.id}")

      # Navigate to next month
      index_live |> element("button[phx-click='next_month']") |> render_click()

      assert has_element?(index_live, "#transactions-#{feb_tx.id}")
      refute has_element?(index_live, "#transactions-#{jan_tx.id}")
    end

    test "toggles pending (uncategorized) transactions", %{conn: conn} do
      # We need to make sure they are in the same month/year or clear filters
      today = Date.utc_today()

      cat_tx =
        transaction_fixture(
          description: "Categorized",
          category_id: category_fixture().id,
          date: today
        )

      uncat_tx = transaction_fixture(description: "Uncategorized", category_id: nil, date: today)

      {:ok, index_live, _html} =
        live(conn, ~p"/transactions?month=#{today.month}&year=#{today.year}")

      # Toggle pending
      index_live |> element("button[phx-click='toggle_pending']") |> render_click()

      assert render(index_live) =~ "Uncategorized"
      refute render(index_live) =~ "Categorized"
    end

    test "handles large datasets with load-more", %{conn: conn} do
      # Create 60 transactions with different dates to ensure deterministic sort (desc)
      # Tx 60 will be the newest (most recent date)
      today = Date.utc_today()

      for i <- 1..60 do
        transaction_fixture(description: "Tx-#{i}-END", date: Date.add(today, i))
      end

      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Default page size is 50. Tx 60 (most recent) should be visible, Tx 1 (oldest) should not.
      assert render(index_live) =~ "Tx-60-END"
      refute render(index_live) =~ "Tx-1-END"

      # Load more
      render_hook(index_live, "load-more", %{})

      assert render(index_live) =~ "Tx-1-END"
    end
  end

  describe "File Ingestion" do
    test "opens and closes import modal", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Ensure modal is closed
      refute has_element?(index_live, "#import-modal")

      # Open
      index_live |> element("button[phx-click='open_import']") |> render_click()
      assert has_element?(index_live, "#import-modal")

      # Close
      index_live |> element("#import-modal button[aria-label='close']") |> render_click()
      refute has_element?(index_live, "#import-modal")
    end

    test "handles file upload flow", %{conn: conn} do
      account = account_fixture(accepts_import: true, parser_type: "bb_csv")
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      index_live |> element("button", "Importar Extratos") |> render_click()

      # Select account
      index_live |> form("#upload-form") |> render_change(%{account_id: account.id})

      # Mock file upload
      file =
        file_input(index_live, "#upload-form", :statement, [
          %{
            last_modified: 1_594_171_200_000,
            name: "bb_sample.csv",
            content: File.read!("test/support/fixtures/files/bb_sample.csv"),
            type: "text/csv"
          }
        ])

      render_upload(file, "bb_sample.csv")

      # Submit
      index_live |> form("#upload-form") |> render_submit()

      assert render(index_live) =~ "Sucesso!"
      assert render(index_live) =~ "3 transações importadas"
    end
  end

  describe "UI State & Modals" do
    setup [:create_transaction]

    test "persists filters during navigation", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/transactions")

      # Apply filter
      index_live
      |> form("#transaction-filters", %{"search" => "something"})
      |> render_change()

      # Verify the form input itself contains the value
      assert element(index_live, "input[name='search']") |> render() =~ "value=\"something\""
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
end
