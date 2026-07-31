defmodule CashLensWeb.TransactionLive.PluggyImportTest do
  use CashLensWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CashLens.AccountsFixtures
  import CashLens.PluggyFixtures

  alias CashLens.Pluggy

  setup do
    item = pluggy_item_fixture()
    account = account_fixture(%{name: "Conta Corrente"})

    {:ok, link} =
      Pluggy.upsert_account_link(item, %{
        pluggy_account_id: "acc-1",
        pluggy_account_name: "Conta Corrente",
        pluggy_account_type: "BANK"
      })

    {:ok, _link} = Pluggy.link_account(link, account.id)

    %{account: account}
  end

  test "clicking Importar do Pluggy without credentials configured flashes an error", %{
    conn: conn
  } do
    System.delete_env("PLUGGY_CLIENT_ID")
    System.delete_env("PLUGGY_CLIENT_SECRET")

    {:ok, live, _html} = live(conn, ~p"/transactions")

    html = render_click(live, "import_pluggy", %{})

    assert html =~ "PLUGGY_CLIENT_ID" or html =~ "não configuradas" or
             html =~ "não configurado"
  end

  test "the button is present in the actions menu", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/transactions")

    assert has_element?(live, "button[phx-click='import_pluggy']")
  end
end
