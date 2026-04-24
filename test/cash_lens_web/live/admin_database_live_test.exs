defmodule CashLensWeb.AdminDatabaseLiveTest do
  use CashLensWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders tables list and selects table", %{conn: conn} do
    CashLens.AccountsFixtures.account_fixture(%{name: "DBTestAccount"})
    {:ok, live, _html} = live(conn, ~p"/admin/db")
    assert render(live) =~ "Administração do Banco de Dados"

    {:ok, live, _html} = live(conn, ~p"/admin/db/accounts")
    assert render(live) =~ "DBTestAccount"

    # Testing filter
    html =
      live
      |> form("#filter-form-accounts", %{"filters" => %{"name" => "NonExistent"}})
      |> render_change()

    assert html =~ "Nenhum registro encontrado"
  end
end
