defmodule CashLensWeb.TransactionLive.IndexTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.CategoriesFixtures
  import CashLens.TransactionsFixtures

  describe "import entry point" do
    test "the actions dropdown links to /imports instead of opening a modal", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/transactions")

      assert html =~ ~s(href="/imports")
      assert html =~ "Importar Extratos"
      refute html =~ "Importar em Lote"
    end
  end
end
