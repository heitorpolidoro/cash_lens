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
end
