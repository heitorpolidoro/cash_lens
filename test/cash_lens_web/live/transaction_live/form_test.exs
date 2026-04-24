defmodule CashLensWeb.TransactionLive.FormTest do
  use CashLensWeb.ConnCase
  import Phoenix.LiveViewTest
  import CashLens.TransactionsFixtures
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures

  @create_attrs %{
    date: Date.to_iso8601(Date.utc_today()),
    description: "New Form Transaction",
    amount: "100.00"
  }
  @update_attrs %{
    description: "Updated description"
  }

  describe "New Transaction" do
    test "renders form and creates transaction", %{conn: conn} do
      account = account_fixture()
      {:ok, live, _html} = live(conn, ~p"/transactions/new")

      assert render(live) =~ "New Transaction"

      assert {:ok, _live, html} =
               live
               |> form("#transaction-form",
                 transaction: Map.put(@create_attrs, :account_id, account.id)
               )
               |> render_submit()
               |> follow_redirect(conn, ~p"/transactions")

      assert html =~ "Transaction created successfully"
    end

    test "validates required fields", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions/new")

      result =
        live
        |> form("#transaction-form", transaction: %{description: ""})
        |> render_change()

      assert result =~ "can&#39;t be blank"
    end

    test "handles error on save", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/transactions/new")

      result =
        live
        |> form("#transaction-form", transaction: %{description: ""})
        |> render_submit()

      assert result =~ "can&#39;t be blank"
    end
  end

  describe "Edit Transaction" do
    test "updates transaction and returns to index by default", %{conn: conn} do
      account = account_fixture()
      tx = transaction_fixture(account_id: account.id)
      {:ok, live, _html} = live(conn, ~p"/transactions/#{tx}/edit")

      assert render(live) =~ "Edit Transaction"

      assert {:ok, _live, html} =
               live
               |> form("#transaction-form", transaction: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn, ~p"/transactions")

      assert html =~ "Transaction updated successfully"
    end

    test "updates transaction and returns to show when return_to=show", %{conn: conn} do
      account = account_fixture()
      tx = transaction_fixture(account_id: account.id)
      {:ok, live, _html} = live(conn, ~p"/transactions/#{tx}/edit?return_to=show")

      result =
        live
        |> form("#transaction-form", transaction: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/transactions/#{tx}")

      assert {:ok, _live, html} = result
      assert html =~ "Transaction updated successfully"
    end
  end
end
