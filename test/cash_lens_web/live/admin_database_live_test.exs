defmodule CashLensWeb.AdminDatabaseLiveTest do
  use CashLensWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders tables list and selects table", %{conn: conn} do
    CashLens.AccountsFixtures.account_fixture(%{name: "DBTestAccount"})
    {:ok, live, _html} = live(conn, ~p"/admin/db")
    assert render(live) =~ "Database Administration"

    {:ok, live, _html} = live(conn, ~p"/admin/db/accounts")
    assert render(live) =~ "DBTestAccount"

    # Testing filter
    html =
      live
      |> form("#filter-form-accounts", %{"filters" => %{"name" => "NonExistent"}})
      |> render_change()

    assert html =~ "No records found for the applied filters."
  end

  test "fetch_rows error path: invalid column name in filter", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/admin/db/accounts")

    # Bypass form validation by sending the event directly with a non-existent column,
    # which triggers a SQL error in Repo.query -> {:error, _} -> rows: []
    html = render_click(live, "filter", %{"filters" => %{"nonexistent_col_xyz" => "value"}})

    assert html =~ "0 records"
  end

  test "runs the batch installment scan delegated from the installments screen", %{conn: conn} do
    acc = CashLens.AccountsFixtures.account_fixture(%{name: "ScanAccount"})

    for n <- 1..2 do
      CashLens.TransactionsFixtures.transaction_fixture(%{
        account_id: acc.id,
        amount: "-50.00",
        description: "EC LOJA PARC 0#{n}/02 BR",
        date: ~D[2026-01-10]
      })
    end

    {:ok, live, html} = live(conn, ~p"/admin/db")
    assert html =~ "Detectar Parcelamentos"

    html = render_click(live, "detect_installments", %{})
    assert html =~ "detectada(s)"
  end
end
